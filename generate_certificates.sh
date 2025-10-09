#!/bin/bash

# Exit on any error, print all commands
set -o nounset \
    -o errexit

# --- 1. CA Setup ---
# Ensure the "certs" directory exists
if [ ! -d "certs" ]; then
  mkdir -p certs/ca
fi
# Clean up previous files and set up CA directory structure
cd certs
rm -rf *.pem *.pem.attr
rm -rf ca/serial* ca/index* ca/certsdb*
rm -f global.truststore.jks
touch ca/serial
echo 1000 > ca/serial
touch ca/index

# Generate the Certificate Authority (CA) key and self-signed certificate
# This creates cacert.pem (the public cert) and cakey.pem (the private key)
openssl req -new -x509 \
    -config ca/openssl-ca.cnf \
    -keyout cakey.pem \
    -out cacert.pem \
    -newkey rsa:4096 \
    -sha256 \
    -nodes \
    -subj '/CN=ca1.test.confluent.io/OU=TEST/O=CONFLUENT/L=PaloAlto/ST=Ca/C=US' \
    -passin pass:confluent

echo "✅ CA certificate and key generated."

# Create truststore and import the CA cert
keytool -noprompt -importcert \
        -keystore global.truststore.jks \
        -alias CARoot \
        -file cacert.pem \
        -storepass confluent \
        -storetype PKCS12

# --- 2. Component Certificate Generation ---
# Loop through each component to generate its keystore and truststore
for i in kraftcontroller kafka connect schemaregistry cmf krp flink-app1 elasticsearch-es-http
do
  echo ""
  echo "------------------------------- $i -------------------------------"
  rm -rf $i
  mkdir -p $i

  # Create host keystore
  keytool -genkey -noprompt \
  	  -alias $i \
  	  -dname "CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
          -ext san=DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local,DNS:$i-service \
  	  -keystore $i/$i.keystore.jks \
  	  -keyalg RSA \
  	  -storepass confluent \
  	  -keypass confluent \
  	  -validity 999 \
  	  -storetype pkcs12

  # Create the certificate signing request (CSR)
  keytool -certreq \
          -keystore $i/$i.keystore.jks \
          -alias $i \
          -storepass confluent \
          -keypass confluent \
          -storetype pkcs12 \
          -ext san=DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local,DNS:$i-service \
          -file $i/$i.csr

  # Sign the host certificate with the certificate authority (CA)
  openssl ca \
          -config ca/openssl-ca.cnf \
          -policy signing_policy \
          -extensions signing_req \
          -passin pass:confluent \
          -batch \
          -out $i/$i-signed.crt \
          -in $i/$i.csr

  # Import the CA cert into the keystore
  keytool -noprompt -importcert \
          -alias CARoot \
          -file cacert.pem \
          -keystore $i/$i.keystore.jks \
          -storepass confluent \
          -storetype pkcs12

  # Import the signed host certificate, associating it with the existing private key alias
  keytool -noprompt -importcert \
          -keystore $i/$i.keystore.jks \
          -alias $i \
          -file $i/$i-signed.crt \
          -storepass confluent \
          -storetype pkcs12

  # Import the cert in the truststore
  keytool -importcert -noprompt \
    -alias $i \
    -file $i/$i-signed.crt \
    -keystore global.truststore.jks \
    -storepass confluent \
    -storetype PKCS12

  # Save creds
  echo -n "jksPassword=confluent" > $i/${i}.jksPassword.txt

  # Copy the CA certificate to the component's directory for easy access
  cp cacert.pem $i/ca.pem

  # Clean up the intermediate CSR file
  rm $i/$i.csr

  echo ""
  echo "✅ KeyStore and TrustStore certificates generated for $i in directory: $i/"
done


# --- 3. Control Center Certificate Generation ---
# For some reason, I could not make C3++ work with keystore/truststore, but needed pem certs
for i in prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass connector
do
  echo "------------------------------- $i -------------------------------"
  #rm -rf $i
  mkdir -p $i

  # Generate the private key
  openssl genrsa -out $i/key.pem 4096

  # Create the Certificate Signing Request (CSR)
  # The SAN (Subject Alternative Name) is crucial for proper hostname validation
  openssl req -new \
          -key $i/key.pem \
          -subj "/CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
          -addext "subjectAltName=DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local" \
          -out $i/$i.csr

  # Sign the CSR with our CA
  # This creates the final, signed public certificate for the component
  openssl ca \
          -config ca/openssl-ca.cnf \
          -policy signing_policy \
          -extensions signing_req \
          -passin pass:confluent \
          -batch \
          -out $i/$i.pem \
          -in $i/$i.csr

  keytool -importcert -noprompt \
    -alias $i-pem \
    -file $i/$i.pem \
    -keystore global.truststore.jks \
    -storepass confluent \
    -storetype PKCS12

  # Copy the CA certificate to the component's directory for easy access
  cp cacert.pem $i/ca.pem

  # Clean up the intermediate CSR file
  rm $i/$i.csr

  echo ""
  echo "✅ PEM certificates generated for $i in directory: $i/"
done

for i in kraftcontroller kafka connect schemaregistry cmf prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass krp connector flink-app1 elasticsearch-es-http
do
  cp global.truststore.jks ./$i/$i.truststore.jks
done

cp -r flink-app1 ../flink-sql/flink-sql-runner-example/flink-app1

rm 1*.pem

echo ""
echo "🎉🎉 All certificates have been generated successfully."
