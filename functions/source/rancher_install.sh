REGION=$1
EKSCLUSTERNAME=$2

export RancherURL="rancheraws.example.com"
export HostedZone="rancheraws.example.com."

#Install tools
sudo yum -y install jq

aws eks update-kubeconfig --name ${EKSCLUSTERNAME} --region $REGION

#Install kubectl
#sudo curl --silent --location -o /usr/local/bin/kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.17.7/2020-07-08/bin/linux/amd64/kubectl
#
#curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.19.0/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
kubectl version --client

# Install helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Start by creating the mandatory resources for NGINX Ingress in your cluster:
# Parameterize version 0.40.1
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.40.1/deploy/static/provider/aws/deploy.yaml

#Download latest Rancher repository
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm fetch rancher-stable/rancher

# Create NameSpace:
kubectl create namespace cattle-system

# The Rancher management server is designed to be secure by default and requires SSL/TLS configuration.
# Defining the Ingress resource (with SSL termination) to route traffic to the services created above 
# Example ${RancherURL} is like ranchereksqs.awscloudbuilder.com
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout tls.key -out tls.crt -subj "/CN=${RancherURL}/O=${RancherURL}"

#Create the secret in the cluster:
kubectl create secret tls tls-secret --key tls.key --cert tls.crt

helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=${RancherURL}  \
  --set ingress.tls.source=secret

# IAM role for route 53 and NLB HostedZoneId:
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {
#             "Sid": "VisualEditor0",
#             "Effect": "Allow",
#             "Action": [
#                 "route53:CreateHostedZone",
#                 "route53:DisassociateVPCFromHostedZone",
#                 "route53:GetHostedZone",
#                 "route53:ListHostedZones",
#                 "route53:ChangeResourceRecordSets",
#                 "route53:CreateQueryLoggingConfig",
#                 "route53:CreateVPCAssociationAuthorization",
#                 "route53:UpdateHealthCheck",
#                 "route53:DeleteHealthCheck",
#                 "route53:ListHostedZonesByName",
#                 "route53:DeleteVPCAssociationAuthorization",
#                 "route53:CreateHealthCheck",
#                 "route53:ListResourceRecordSets",
#                 "route53:DeleteHostedZone",
#                 "route53:AssociateVPCWithHostedZone",
#                 "route53:UpdateHostedZoneComment",
#                 "route53:DeleteQueryLoggingConfig",
#                 "elasticloadbalancing:DescribeLoadBalancers"
#             ],
#             "Resource": "*"
#         }
#     ]
# }

#Create Route53 Hosted Zone
export CALLER_REF=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo '')
#aws route53 create-hosted-zone --name ranchereksjon.awscloudbuilder.com. --caller-reference $CALLER_REF --hosted-zone-config Comment="Rancher Domain"
aws route53 create-hosted-zone --name ${HostedZone} --caller-reference $CALLER_REF --hosted-zone-config Comment="Rancher Domain"

#Extract Hosted Zone ID:
# HOSTED_ZONE_ID=$( aws route53 list-hosted-zones-by-name | grep -B 1 -e "ranchereksjon.awscloudbuilder.com" | sed 's/.*hostedzone\/\([A-Za-z0-9]*\)\".*/\1/' | head -n 1 )
export ZONE_ID=$(aws route53 list-hosted-zones-by-name |  jq --arg name "${RancherURL}." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id')
export ZONE_ID=$(echo $ZONE_ID | tr --delete /hostedzone/)

#Create Resource Record Set
export NLB=$(kubectl get svc -n ingress-nginx -o json | jq -r ".items[0].status.loadBalancer.ingress[0].hostname")
kubectl get svc -n ingress-nginx -o json | jq -r ".items[0].status.loadBalancer.ingress[0].hostname" > rancher-nlb.txt
sed -i.bak 's/-.*//g' rancher-nlb.txt
cat rancher-nlb.txt
export NLB_NAME=$(cat rancher-nlb.txt)
# aws elbv2 describe-load-balancers --region us-east-1 --names $NLB_NAME | jq -r ".LoadBalancers[0].CanonicalHostedZoneId"

#Create Resource Record Set
# export NLB_HOSTEDZONE=$(aws elbv2 describe-load-balancers --region us-east-1 --names $NLB_NAME | jq -r ".LoadBalancers[0].CanonicalHostedZoneId")
export NLB_HOSTEDZONE=$(aws elbv2 describe-load-balancers --region us-east-2 --names $NLB_NAME | jq -r ".LoadBalancers[0].CanonicalHostedZoneId")

cat > rancher-record-set.json <<EOF
{
	"Comment": "CREATE/DELETE/UPSERT a record ",
	"Changes": [{
		"Action": "UPSERT",
		"ResourceRecordSet": {
			"Name": "${RancherURL}.",
            "SetIdentifier": "RancherEKS",
            "Region": "${AWS::Region}",
			"Type": "A",
			"AliasTarget": {
				"HostedZoneId": "zone-id",
				"DNSName": "dualstack.nlb-dns",
				"EvaluateTargetHealth": false
			}
		}
	}]
}
EOF

sed -i "s/zone-id/${NLB_HOSTEDZONE}/g" rancher-record-set.json
sed -i "s/nlb-dns/${NLB}/g" rancher-record-set.json
cat rancher-record-set.json
aws route53 change-resource-record-sets --region us-east-2 --hosted-zone-id $ZONE_ID --change-batch file://rancher-record-set.json
