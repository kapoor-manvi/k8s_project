# Deploying a Flask API and Postgres SQL
 server on Kubernetes

This repo contains code that 
1) Deploys AWS EKS cluster using terraform. 
2) Deploys a postgres server and a flask api on a Kubernetes cluster 
3) Attaches a persistent volume to it, so the data remains contained if pods are restarting
4) Deploys a Flask API to add a transaction to the postgres database.

## Prerequisites
1. Have `Docker`, `AWS CLI`, `Helm` and the `Kubernetes CLI` (`kubectl`) installed

## Getting started locally
1. Clone the repository
2. Change directory to app `cd app`
3. Test the app locally `docker-compose up --build`
4. Start making requests `curl -X POST http://localhost:5000/api/transaction \`
   `-H "Content-Type: application/json" \`
   `-d '{`
      `"transactionId": "12345",`
      `"amount": 100.0,`
      `"timestamp": "2024-08-01T12:00:00"`
    `}'`

## Provision EKS Cluster
1. `cd terraform`
2. `terraform init`
3. `terraform apply -target="module.vpc" -auto-approve`
4. `terraform apply -target="module.eks" -auto-approve`
5. `terraform apply -auto-approve`

## Configure Kubectl to point to EKS cluster
   `aws eks update-kubeconfig --name external-secrets --region us-west-2`

## Public ECR to store the docker image
1. Create a public ECR repository in the AWS account.
2. docker login
   `aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY/$ECR_REPOSITORY`

3. Build the Docker image
   `docker build . -t $ECR_REPOSITORY:$IMAGE_TAG`

4. Tag the image for ECR
   `docker tag $ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG`

5. Push the image to ECR
   `docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG`


## Deployments
Get the secrets, configmap, persistent volume in place and apply the deployments for the `Postgres` database and `Flask API`

1. Add the secrets to your `kubernetes cluster`: `kubectl apply -f secret.yml`
2. Create the `persistent volume` and `persistent volume claim` for the database: `kubectl apply -f pv.yml` and `kubectl apply -f pvc.yml`
3. Create the `postgres init script configmap`  for the `posgres`deployment: `kubectl apply -f config-map.yml`
4. Create the `postgres` deployment and service : `kubectl apply -f postgres_deployment.yml` and `kubectl apply -f postgres_service.yml`
4. Create the `Flask API i.e. transaction api` deployment and service : `kubectl apply -f app_deployment.yml` and `kubectl apply -f service.yml`
5. Install ALB ingress controller using the steps mentioned in [https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html]
6. Create the ingress resource which will create the ALB for the api : `kubectl apply -f ingress.ym`


## Observability:

1. Installed Prometheus using helm 
`kubectl create namespace prometheus`
`helm repo add prometheus-community https://prometheus-community.github.io/helm-charts`
`helm upgrade -i prometheus prometheus-community/prometheus \`
    `--namespace prometheus \`
    `--set alertmanager.persistence.storageClass="gp2" \`
    `--set server.persistentVolume.storageClass="gp2"`
`
2. Installed Grafana using helm
`kubectl create namespace grafana`
   `helm install grafana grafana/grafana \`
    `--namespace grafana \`
    `--set persistence.storageClassName="gp2" \`
    `--set persistence.enabled=true \`
    `--set adminPassword='EKS!sAWSome' \`
    `--values ${HOME}/environment/grafana/grafana.yaml \`


3. Installed Jaegar using helm
4. Expose Prometheus 
`kubectl --namespace=prometheus port-forward deploy/prometheus-server 9090`
5. Expose Grafana
`kubectl --namespace grafana port-forward ${POD_NAME} 3000`
6. Setup Grafana dashboards by exporting existing dashboards for cluster and pod monitoring like 3119 and 9144.



    
## Start making requests
Now you can use the `API` to add a transaction to your database using the ALB endpoint: 
1. add a transaction: `curl --header "Content-Type: application/json" \
`-X POST http://k8s-external-ingress2-a2e988e138-292322854.us-west-2.elb.amazonaws.com/api/transaction \`
`--data '{"transactionId":"07e4fgdgh-c685-4df9-je27-u75e7ac8ba7a",`
`"amount": 99.90,"timestamp":"2009-09-28T17:03:18"}'`


## Ideas to make the project and security posture better.
1) App code: can have /heathcheck to monitor the healthcheck of the api. Some landing message for the / context.
2) App code: Better error handling, for eg. if a transactionId exist then the API should not throw 500 but give the proper message"
3) App code should handle the database initialisation and migrations. May be I could have used alembic for that.
4) K8s/Security: The kubernetes secrets should be pulled from some kind of secret store eg. vault or secrets manager.
5) K8s: Both the api and database kubernetes deployments should have resource limits set within the manifest.
6) K8s: Both the api and database deployments should have readiness and liveness probe in the deployment manifest.
7) K8s: The blue green or canary deployment strategy should be considered
Terraform: The terraform should have a S3 backend and dynamodb to maintain statefile lock state.
8) Terraform: The monitoring stack installed using helm should be part of the terraform Code.
9) Monitoring: The monitoring stack should have a proper ALB endpoint to view them in the browser.
10) Monitoring: Implement Log aggregation using fluentbit maybe for centralised logging and setup alerts based on errors and error rate
11) Monitoring: Setup alerts in Gafana for CPU, Memory, Disk utilisation on the nodes within the cluster. 
12) Security: Implement Static Code Analysis, Security Scanning, Software Dependency Analysis within the CI/CD pipeline.
13) Security: Implement Image and Container scanning with tools like prisma, aqua, etc. Image scanning should be included in the main eks-deploy workflow and should fail the build if any Critical vulnerability is found.
14) Autoscaling: Use Horizontal pod scaling to scale up or down based on pod resource metrics in this case as the api and database are running in different pods.
15) Security: Secure the external api with SSL.
16) Package all the kubernetes manifests as a helm package and reduce the complexity of deploying resources.


## Challenges faced
1) The ExternalSecrets  and ClusterStore resource to pull secrets from secrets manager in EKS secrets is not working. Got it working by making the change in the ClusterSecretStore provider and using the required service account ref "external-secrets-sa".

2) Docker image built on MacOs (Local) was not compatible with the EKS nodes OS. 
Got it working locally by using 
`docker buildx create --use --name mybuild node-amd64 mybuild`
`docker buildx create --append --name mybuild node-arm64`
`docker buildx build --platform linux/amd64,linux/arm64 .`

3) Opentelemetry container deployment is failing with RuntimeContainer Error.

4) CodeQL analysis doesn't work for non enterprise github repositories.


## Refrences:
https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/external-secrets/

https://grafana.com/solutions/kubernetes/kubernetes-monitoring-introduction/?pg=dashboards&plcmt=featured-dashboard-1

https://archive.eksworkshop.com/intermediate/240_monitoring/

https://www.eksworkshop.com/docs/security/secrets-management/secrets-manager/external-secrets




