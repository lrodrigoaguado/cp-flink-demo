#!/bin/bash

# Exit on any error, print all commands
set -o nounset \
    -o errexit

for i in kraftcontroller kafka connect schemaregistry cmf krp flink-app1
do

  kubectl create secret generic $i-tls \
    --from-file=keystore.jks=./certs/$i/$i.keystore.jks \
    --from-file=truststore.jks=./certs/$i/$i.truststore.jks \
    --from-file=jksPassword.txt=./certs/$i/$i.jksPassword.txt \
    --namespace confluent
done


for i in prometheus-client alertmanager-client prometheus alertmanager controlcenter-ng cmfrestclass connector
do
  kubectl create secret generic $i-tls \
    --from-file=fullchain.pem=./certs/$i/$i.pem \
    --from-file=cacerts.pem=./certs/$i/ca.pem  \
    --from-file=privkey.pem=./certs/$i/key.pem  \
    --namespace confluent
done
