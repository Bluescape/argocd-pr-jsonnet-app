#!/bin/bash

GITHUB_PAT=${1}
ORG=${2}
INFRA_REPO=${3}
PR_REF=${4}
ENVIRONMENT=${5}
DOMAIN=${6}
IMAGE=${7}
TAG=${8}
AWS_ACCESS_KEY_ID=${9}
AWS_SECRET_ACCESS_KEY=${10}
AWS_DEFAULT_REGION=${11}
AWS_ORG_ID=${12}

echo "<<<< Cloning infrastructure repo ${ORG}/${INFRA_REPO}"
git clone https://${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}.git
cd infrastructure
ENVIRONMENT=pre-prod
TAG=latest-release
echo "ENV ${ENVIRONMENT}"
echo ${AWS_DEFAULT_REGION}
echo ${INPUT_AWS_ACCESS_KEY_ID}
aws configure set region ${AWS_DEFAULT_REGION}
aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
aws configure set role_arn "arn:aws:iam::${AWS_ORG_ID}:role/adminAssumeRole"
aws configure set source_profile default
if [[ ${ENVIRONMENT} = 'pre-prod' ]];  then
aws eks update-kubeconfig --role-arn "arn:aws:iam::${AWS_ORG_ID}:role/adminAssumeRole" --name="pre-prod-b" --kubeconfig /kubeconfig --profile default
else
aws eks update-kubeconfig --role-arn "arn:aws:iam::${AWS_ORG_ID}:role/adminAssumeRole" --name="alpha-b" --kubeconfig /kubeconfig --profile default
fi
export KUBECONFIG=/kubeconfig

echo ">>>> kubeconfig created"


git config --local user.name "GitHub Action"
git config --local user.email "action@github.com"
git remote set-url origin https://x-access-token:${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}
git fetch --all

echo ">>>> Compiling manifests for"
echo "ref ${PR_REF}"
echo "cluster ${CLUSTER}"
echo "domain ${DOMAIN}"
echo "image ${IMAGE}:${TAG}"

REGEX="[a-zA-Z]+-[0-9]{1,5}"

## Deploy to staging if branch is develop, release, main or master
## Note: infrastrucure branch is using master
# if [[ ${PR_REF} =~ ^refs/heads/(master|develop|release|main)$ ]]; then
#   export NAMESPACE=staging
#   export BRANCH=master
#   git checkout master

# ##
# # checking if this is a feature branch or release
# elif [[ ${PR_REF} =~ ${REGEX} ]]; then
#   ##
#   # If branch does not exist create it
#   export BRANCH=${PR_REF}
#   git checkout ${BRANCH} || git checkout -b ${BRANCH}

#   ##
#   # set namespace as jira issue id extracted from branch name and make sure it is lowercase
#   export NAMESPACE=$(echo ${BASH_REMATCH[0]} |  tr '[:upper:]' '[:lower:]')

# else
#   echo "<<<< ${PR_REF} cannot be deployed, it is not a feature branch nor a release"
#   exit 1
# fi


git checkout  auto-sync-image

getValue(){
    echo ${1} | base64 --decode | jq -r ${2}
}

cd jsonnet/${ORG}

compileManifest(){
if CLUSTER=${1} DOMAIN=${DOMAIN} NAMESPACE=${2} IMAGE=${IMAGE} TAG=${TAG} ./compile.sh ; then
    echo "Compile succeeded"
else
    echo "Compile failed"
    exit 1
fi 
}


deployManifest(){
kubectl --kubeconfig=${KUBECONFIG} -n argocd apply -f -<<EOF
        kind: Application
        apiVersion: argoproj.io/v1alpha1
        metadata:
          name: ${2}
          namespace: argocd
        spec:
          destination:
            namespace: ${2}
            server: 'https://kubernetes.default.svc'
          project: default
          source:
            path: jsonnet/${ORG}/clusters/${1}/manifests
            repoURL: git@github.com:${ORG}/${INFRA_REPO}.git
            targetRevision: ${BRANCH}
          syncPolicy:
            automated: {}
EOF
}


if [[ ${ENVIRONMENT} = 'ondemand' ]];  then
  compileManifest ${ENVIRONMENT} ${NAMESPACE}
  #  deployManifest k
else  
  clusters=`cat images-auto-sync.json`
   echo "${clusters}"
  for row in $(echo "${clusters}" | jq -r '.[] | @base64'); do
      environment=$(getValue ${row} '.environment')
      cluster=$(getValue ${row} '.cluster')
      echo ${ENVIRONMENT} ${environment}
      namespace=$(getValue ${row} '.namespace')
      if [[ ${ENVIRONMENT} = ${environment} ]];  then
          compileManifest ${cluster} ${namespace} 
          # deployManifest()
      fi
  done
fi  

git add -A
          
## If there is nothing to commit exit without fail to continue
# this will happan if you running a deployment manually for a specific commit 
# so there will be no changes in the compiled manifests since no new docker image created
git commit -am "recompiled deployment manifests" || exit 0
echo ">>> git push --set-upstream origin ${BRANCH}"
git push --set-upstream origin auto-sync-image

echo ">>> Completed"

