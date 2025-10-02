#!/bin/bash

# Revised v2: generate_certificates.sh (wildcard-safe + pod FQDNs)
# - Adds DNS:*.${i}.confluent.svc.cluster.local to cover StatefulSet pod hostnames like
#   kafka-0.kafka.confluent.svc.cluster.local and kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local
# - Keeps structure and passwords as before.
#
# Requires: openssl, keytool
set -o nounset -o errexit

# --- 1. CA Setup ---
if [ ! -d "certs" ]; then
  mkdir -p certs/ca
fi

cd certs
rm -rf *.pem *.pem.attr
rm -rf ca/serial* ca/index* ca/certsdb*
rm -f global.truststore.jks
touch ca/serial
echo 1000 > ca/serial
touch ca/index

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

keytool -noprompt -importcert \
        -keystore global.truststore.jks \
        -alias CARoot \
        -file cacert.pem \
        -storepass confluent \
        -storetype PKCS12

echo "Certificate was added to keystore"
echo ""

# Helper to build SAN list for a component
build_san() {
  local name="$1"
  # Base names
  local sans="DNS:${name},DNS:${name}.confluent.svc.cluster.local,DNS:${name}-service"
  # Wildcards:
  #  - *.confluent.svc.cluster.local   -> covers single-label hosts like schemaregistry.confluent.svc.cluster.local
  #  - *.${name}.confluent.svc.cluster.local -> covers pod hosts like name-0.name.confluent.svc.cluster.local
  sans="${sans},DNS:*.confluent.svc.cluster.local,DNS:*.${name}.confluent.svc.cluster.local"
  echo "${sans}"
}

# --- 2. Component Certificate Generation (OpenSSL + import to JKS) ---
for i in kraftcontroller kafka connect schemaregistry cmf krp flink-app1
do
  echo "------------------------------- $i -------------------------------"
  rm -rf "$i"
  mkdir -p "$i"

  openssl genrsa -out "$i/key.pem" 4096

  SAN_LIST=$(build_san "$i")

  # Create CSR with full SANs (includes *.${i}.confluent.svc.cluster.local)
  openssl req -new \
      -key "$i/key.pem" \
      -subj "/CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
      -addext "subjectAltName=${SAN_LIST}" \
      -out "$i/$i.csr"

  # Sign CSR
  openssl ca \
      -config ca/openssl-ca.cnf \
      -policy signing_policy \
      -extensions signing_req \
      -passin pass:confluent \
      -batch \
      -out "$i/$i-signed.crt" \
      -in "$i/$i.csr"

  # PKCS12 with chain
  openssl pkcs12 -export \
      -in "$i/$i-signed.crt" \
      -inkey "$i/key.pem" \
      -certfile cacert.pem \
      -name "$i" \
      -out "$i/$i.p12" \
      -passout pass:confluent

  # Import into JKS/PKCS12
  keytool -importkeystore -noprompt \
      -deststorepass confluent \
      -destkeypass confluent \
      -deststoretype pkcs12 \
      -destkeystore "$i/$i.keystore.jks" \
      -srckeystore "$i/$i.p12" \
      -srcstoretype PKCS12 \
      -srcstorepass confluent \
      -alias "$i"

  # Ensure CA root present
  keytool -noprompt -importcert \
      -alias CARoot \
      -file cacert.pem \
      -keystore "$i/$i.keystore.jks" \
      -storepass confluent \
      -storetype pkcs12 || true

  # Add the signed cert to global truststore (as before)
  keytool -importcert -noprompt \
      -alias "$i" \
      -file "$i/$i-signed.crt" \
      -keystore global.truststore.jks \
      -storepass confluent \
      -storetype PKCS12

  echo -n "jksPassword=confluent" > "$i/${i}.jksPassword.txt"
  cp cacert.pem "$i/ca.pem"
  rm -f "$i/$i.csr"

  # Quick print of SANs for verification
  echo "SANs for $i: ${SAN_LIST}"
  echo "✅ KeyStore and TrustStore certificates generated for $i"
  echo ""
done

# --- 3. Control Center / Auxiliary PEM Certificates ---
for i in prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass connector
do
  echo "------------------------------- $i -------------------------------"
  mkdir -p "$i"

  openssl genrsa -out "$i/key.pem" 4096

  SAN_LIST=$(build_san "$i")

  openssl req -new \
          -key "$i/key.pem" \
          -subj "/CN=$i,OU=TEST,O=CONFLUENT,L=PaloAlto,S=Ca,C=US" \
          -addext "subjectAltName=${SAN_LIST}" \
          -out "$i/$i.csr"

  openssl ca \
          -config ca/openssl-ca.cnf \
          -policy signing_policy \
          -extensions signing_req \
          -passin pass:confluent \
          -batch \
          -out "$i/$i.pem" \
          -in "$i/$i.csr"

  keytool -importcert -noprompt \
    -alias "$i-pem" \
    -file "$i/$i.pem" \
    -keystore global.truststore.jks \
    -storepass confluent \
    -storetype PKCS12

  cp cacert.pem "$i/ca.pem"
  rm -f "$i/$i.csr"

  echo "SANs for $i: ${SAN_LIST}"
  echo "✅ PEM certificates generated for $i"
  echo ""
done

# Distribute truststore copies
for i in kraftcontroller kafka connect schemaregistry cmf prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass krp connector flink-app1
do
  cp global.truststore.jks "./$i/$i.truststore.jks" || true
done

if [ -d ../flink-sql/flink-sql-runner-example ]; then
  cp -r flink-app1 ../flink-sql/flink-sql-runner-example/flink-app1
fi

rm -f 1*.pem || true

echo ""
echo "🎉 All certificates have been generated successfully (now covering pod FQDNs like name-0.name.confluent.svc.cluster.local)."
