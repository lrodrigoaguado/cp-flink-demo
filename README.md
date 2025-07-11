# CP Flink SQL

- [CP Flink SQL](#cp-flink-sql)
  - [Disclaimer](#disclaimer)
- [Setup](#setup)
  - [Deploy Kubernetes](#deploy-kubernetes)
  - [Start Confluent Platform](#start-confluent-platform)
  - [Install CP Flink](#install-cp-flink)
  - [Feed test data](#feed-test-data)
  - [Process the data with Flink](#process-the-data-with-flink)
  - [Option 1: Deploy a FlinkEnvironment and a FlinkApplication declaratively](#option-1-deploy-a-flinkenvironment-and-a-flinkapplication-declaratively)
  - [Cleanup](#cleanup)

## Disclaimer

The code and/or instructions here available are **NOT** intended for production usage.
It's only meant to serve as an example or reference and does not replace the need to follow actual and official documentation of referenced products.

# Setup

## Prerequisites

To run the following demo, you will need an environment with a working version of kind, helm,...

## Deploy Kubernetes
```shell
kind create cluster --image kindest/node:v1.31.0
```

Optionally, if you want to access the Kubernetes dashboard, run these commands in a separate terminal:

```shell
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml --context kind-kind
kubectl create serviceaccount -n kubernetes-dashboard admin-user
kubectl create clusterrolebinding -n kubernetes-dashboard admin-user --clusterrole cluster-admin --serviceaccount=kubernetes-dashboard:admin-user
token=$(kubectl -n kubernetes-dashboard create token admin-user)
echo $token
kubectl proxy
```

Copy the token displayed on output and use it to login at http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/#/login

You may need to wait a couple of seconds for dashboard to become available.

In case you are logged out cause of inactivity you may see errors as:

```
E0225 13:50:19.136484   67149 proxy_server.go:147] Error while proxying request: context canceled
```

Just login again using same token as before and ignore the errors.

## Start Confluent Platform

In your running kubernetes cluster, create now a namespace for the demo, called "confluent" and deploy Confluent's operator:

```shell
kubectl create namespace confluent
kubectl config set-context --current --namespace=confluent
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
helm upgrade --install operator confluentinc/confluent-for-kubernetes
```

Check pod is ready:

```shell
watch kubectl get pods
```

The different components inthe demo will use mTLS, so we have to create certificates and Kubernetes secrets with them. Generate the certificates for all the components in the demo:

```shell
./generate_certificates.sh
```

And now create the corresponding Kubernetes secrets with those certificates:

```shell
./create_secrets.sh
````

Everything is now ready to spin up the CP components. The environment will have:

- 1 kRaft controller v8.0.0
- 3 kafka brokers v8.0.0
- 1 Schema Registry v8.0.0
- 1 Connect worker v8.0.0
- 1 Rest Proxy v8.0.0
- 1 instance of the new Control Center v2.2.0

```shell
kubectl apply -f cp/infra.yaml
```

It will take a while to start all the pieces, you can check the process with the following command:

```shell
watch kubectl -n confluent get pods
```

Once all the pods are up and running, you can create a port-forward to be able to access the Control Center:

```shell
kubectl -n confluent port-forward controlcenter-ng-0 9021:9021 > /dev/null 2>&1 &
```

As HTTPS access is based on the certificates generated at the beginning of the demo, the url to access the Control Center has to match the SAN included in the certificate. In order to be able to reach the Control Center using https://controlcenter-ng.confluent.svc.cluster.local:9021/, you will probably need to include the line

127.0.0.1	    controlcenter-ng.confluent.svc.cluster.local

in you "/etc/hosts" file.

Once all the pods are up and running, and you have forwarded the port, you can access the Control Center here: https://controlcenter-ng.confluent.svc.cluster.local:9021/

At this point you have a working Kafka environment, but Flink is still not vailable (you will see error messages referring to this in the Control Center).

## Install CP Flink

Let's complete the set up now deploying all the necessary pieces to have a Flink environment.

Install certificate manager:

```shell
kubectl create -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
```

Wait until an endpoint IP is assigned when executing the following:

```shell
watch kubectl get endpoints -n cert-manager cert-manager-webhook
```

Now install the Flink Kubernetes Operator:

```shell
kubectl config set-context --current --namespace=confluent
helm upgrade --install cp-flink-kubernetes-operator --version "~1.120.0" confluentinc/flink-kubernetes-operator --set watchNamespaces="{confluent}"
```

With the Operator deployed, now we can deploy Confluent Manager for Apache Flink.It will also have mTLS configured in the file mtls-cmf.yaml, and encryption keys defined, as needed for production use. In case cmf.sql.production=false is defined, no encryption keys are required.

```shell
openssl rand -out ./certs/cmf.key 32
kubectl create secret generic cmf-encryption-key --from-file=encryption-key=./certs/cmf.key -n confluent

helm upgrade --install -f cp/mtls-cmf.yaml cmf confluentinc/confluent-manager-for-apache-flink \
    --set cmf.logging.level.root=debug \
    --set cmf.sql.production=true \
    --set encryption.key.kubernetesSecretName=cmf-encryption-key \
    --set encryption.key.kubernetesSecretProperty=encryption-key \
    --namespace confluent
```

Wait until the CMF operator pod is Running and ready:

```shell
watch kubectl -n confluent get pods
```

And then, forward the port:
```shell
kubectl port-forward service/cmf-service 8080:80 -n confluent > /dev/null 2>&1 &
```

And deploy CMFRestClass, to allow defining FlinkEnvironments and FlinkApplications with CfK:

```shell
kubectl apply -f cp/cmf-rest-class.yaml
```

And check it has been successfully deployed checking:

```shell
kubectl get cmfrestclass cmfrestclass -n confluent -oyaml
```

It may take some seconds, but you should see one instance called "cmfrestclass" and no errors.

## Feed test data

First of all, create the necessary topics, with:

```shell
kubectl apply -f data/topics.yaml
```

And now, instantiate the DatagenConnector in the Connect cluster to generate mock data. In this case the generated data will resemble fleet data of a transports company. Run:

```shell
kubectl apply -f data/data_source.yaml
```

You should be able to see the data flowing into the created topics.

## Process the data with Flink

At this point, the environment is ready and we can start deploying Flink Environment and applications. We can use two different methods for these:

- Using the Flink menu in the new Control Center
- Declaratively, by leveraging yaml files

## Option 1: Deploy a FlinkEnvironment and a FlinkApplication declaratively

We will be leveraging the standard `flink-sql-runner-example` (https://github.com/apache/flink-kubernetes-operator/tree/main/examples/flink-sql-runner-example).

Compile, build the docker image and load in kind (it may take a bit to load cause the flink image is not so small)::

```shell
cd flink-sql/flink-sql-runner-example
mvn clean verify
DOCKER_BUILDKIT=1 docker build . -t flink-sql-runner-example:latest
kind load docker-image flink-sql-runner-example:latest
cd ../..
```

And now create our CP Flink environment:

```shell
kubectl apply -f flink/flink-environment.yaml
```

And after our application:

```shell
kubectl apply -f flink/flink-application.yaml
```

Check pods are ready (1 job manager and 3 task managers):

```shell
watch kubectl get pods
```

















## Cleanup

```shell
kind delete cluster
```
