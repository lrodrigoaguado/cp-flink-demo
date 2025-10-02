#!/bin/bash

# Revised: generate_certificates.sh (wildcard-safe)
# Purpose: Keep the original structure but avoid keytool's SAN wildcard error by generating
#          component certificates with OpenSSL (including *.confluent.svc.cluster.local)
#          and then importing them into PKCS12/JKS.
#
# Notes:
# - Requires: openssl, keytool
# - Passwords/paths match the original script for drop-in use.
# - Uses existing OpenSSL CA config at ca/openssl-ca.cnf (as in the original).
#
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

echo "Certificate was added to keystore"
echo ""

# --- 2. Component Certificate Generation (wildcard-safe via OpenSSL) ---
# Matches the original component list
for i in kraftcontroller kafka connect schemaregistry cmf krp flink-app1
do
  echo "------------------------------- $i -------------------------------"
  rm -rf $i
  mkdir -p $i

  # Generate private key for the component
  openssl genrsa -out $i/key.pem 4096

  # Create CSR with wildcard SAN included via OpenSSL (keytool can't handle it)
  openssl req -new \
      -key $i/key.pem \
      -subj "/CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
      -addext "subjectAltName=DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local,DNS:$i-service" \
      -out $i/$i.csr

  # Sign the CSR with our CA (same OpenSSL CA config as original)
  openssl ca \
      -config ca/openssl-ca.cnf \
      -policy signing_policy \
      -extensions signing_req \
      -passin pass:confluent \
      -batch \
      -out $i/$i-signed.crt \
      -in $i/$i.csr

  # Build a PKCS12 that includes the signed cert + CA chain
  openssl pkcs12 -export \
      -in $i/$i-signed.crt \
      -inkey $i/key.pem \
      -certfile cacert.pem \
      -name $i \
      -out $i/$i.p12 \
      -passout pass:confluent

  # Import PKCS12 into a PKCS12 keystore file (to keep the original extension/format)
  keytool -importkeystore -noprompt \
      -deststorepass confluent \
      -destkeypass confluent \
      -deststoretype pkcs12 \
      -destkeystore $i/$i.keystore.jks \
      -srckeystore $i/$i.p12 \
      -srcstoretype PKCS12 \
      -srcstorepass confluent \
      -alias $i

  # Ensure CA root is also present as a separate trusted entry (as in the original)
  keytool -noprompt -importcert \
      -alias CARoot \
      -file cacert.pem \
      -keystore $i/$i.keystore.jks \
      -storepass confluent \
      -storetype pkcs12 || true

  # Import the signed host certificate into the global truststore (matches original behavior)
  keytool -importcert -noprompt \
      -alias $i \
      -file $i/$i-signed.crt \
      -keystore global.truststore.jks \
      -storepass confluent \
      -storetype PKCS12

  # Save creds
  echo -n "jksPassword=confluent" > $i/${i}.jksPassword.txt

  # Copy the CA certificate
  cp cacert.pem $i/ca.pem

  # Clean up the intermediate CSR file
  rm -f $i/$i.csr

  echo ""
  echo "✅ KeyStore and TrustStore certificates generated for $i in directory: $i/"
done

# --- 3. Control Center / Auxiliary PEM Certificates (unchanged logic; already used OpenSSL) ---
for i in prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass connector
do
  echo "------------------------------- $i -------------------------------"
  mkdir -p $i

  # Generate the private key
  openssl genrsa -out $i/key.pem 4096

  # Create CSR (wildcard allowed here as well)
  openssl req -new \
          -key $i/key.pem \
          -subj "/CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
          -addext "subjectAltName=DNS:$i,DNS:$i.confluent.svc.cluster.local,DNS:*.confluent.svc.cluster.local" \
          -out $i/$i.csr

  # Sign the CSR with our CA
  openssl ca \
          -config ca/openssl-ca.cnf \
          -policy signing_policy \
          -extensions signing_req \
          -passin pass:confluent \
          -batch \
          -out $i/$i.pem \
          -in $i/$i.csr

  # Add to global truststore as in original
  keytool -importcert -noprompt \
    -alias $i-pem \
    -file $i/$i.pem \
    -keystore global.truststore.jks \
    -storepass confluent \
    -storetype PKCS12

  # Copy the CA certificate
  cp cacert.pem $i/ca.pem

  # Clean up the intermediate CSR file
  rm -f $i/$i.csr

  echo ""
  echo "✅ PEM certificates generated for $i in directory: $i/"
done

# Distribute truststore to all component directories (as in original)
for i in kraftcontroller kafka connect schemaregistry cmf prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass krp connector flink-app1
do
  cp global.truststore.jks ./$i/$i.truststore.jks || true
done

# Optional: keep original copy step for flink example if path exists
if [ -d ../flink-sql/flink-sql-runner-example ]; then
  cp -r flink-app1 ../flink-sql/flink-sql-runner-example/flink-app1
fi

# Clean up any leftover CA-issued temp files that start with numbers
rm -f 1*.pem || true

echo ""
echo "🎉🎉 All certificates have been generated successfully (wildcard-safe)."
