#!/bin/bash

GITHUB_PAT=${1}
ORG=${2}
INFRA_REPO=${3}
PR_REF=${4}
CLUSTER=${5}
DOMAIN=${6}
IMAGE=${7}
TAG=${8}
AWS_ACCESS_KEY_ID=${9}
AWS_SECRET_ACCESS_KEY=${10}
AWS_DEFAULT_REGION=${11}
AWS_ORG_ID=${12}
AWS_EKS_CLUSTER_NAME=${13}

SOURCE_BRANCH=ci-fix
TARGET_BRANCH=alpha
REGEX="[a-zA-Z]+-[0-9]{1,5}"
export ON_DEMAND_INSTANCE=false

# Tag for release RC and production tag
if [[ ${PR_REF} =~ ^refs/tags/*.*.*$ ]]; then 
  export SOURCE_BRANCH=release
  RELEASE_NO_TAG=${PR_REF#refs/*/}
  export RELEASE_NO=`echo ${RELEASE_NO_TAG} | awk -F"-" '{print $1}'`
  export RC_NO=`echo ${RELEASE_NO_TAG} | awk -F"-" '{print $2}'`
  export TAG="${TAG}-release-${RELEASE_NO_TAG}"
# Deploy to staging if branch is develop, main or master
# Note: infrastrucure branch is using master  
elif [[ ${PR_REF} =~ ^refs/heads/(master|develop|main)$ ]]; then
  export SOURCE_BRANCH=ci-fix
  export TARGET_BRANCH=alpha
# checking if this is a feature branch or release
elif [[ ${PR_REF} =~ ${REGEX} ]]; then
  ##
  # If branch does not exist create it
  export SOURCE_BRANCH=${PR_REF}
  export TARGET_BRANCH=${PR_REF}
  # set namespace as jira issue id extracted from branch name and make sure it is lowercase
  export NAMESPACE=$(echo ${BASH_REMATCH[0]} |  tr '[:upper:]' '[:lower:]')
  export ON_DEMAND_INSTANCE=true
else
  echo "<<<< ${PR_REF} cannot be deployed, it is not a feature branch nor a release,develop"
  exit 1
fi

TARGET=dev
# target and branch set
if [[ ${CLUSTER} = 'preprod' ]];  then
  export TARGET=preprod
  export TARGET_BRANCH=preprod
elif [[ ${CLUSTER} = 'prod' ]];  then
  export TARGET=prod
  export TARGET_BRANCH=${RELEASE_NO}
fi



echo "<<<< TAG:${TAG} IMAGE:${IMAGE} CLUSTER:${CLUSTER}  PR_REF:{$PR_REF}"
echo "<<<< Cloning infrastructure repo ${ORG}/${INFRA_REPO}"
git clone https://${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}.git 
cd ${INFRA_REPO}
git config --local user.name "GitHub Action"
git config --local user.email "action@github.com"
git remote set-url origin https://x-access-token:${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}
git fetch --all

git checkout ${TARGET_BRANCH} || git checkout -b ${TARGET_BRANCH}
git checkout ${SOURCE_BRANCH} || git checkout -b ${SOURCE_BRANCH}
git restore --source ${TARGET_BRANCH} jsonnet/${ORG}/images.json 

echo ">>>> Compiling manifests for"
echo "ref ${PR_REF}"
echo "cluster ${CLUSTER}"
echo "domain ${DOMAIN}"
echo "image ${IMAGE}:${TAG}"



getValue(){
    echo ${1} | base64 --decode | jq -r ${2}
}

cd jsonnet/${ORG}

compileManifest(){
  echo "<<<< Compile manifest deploy Cluester=${1} RELEASE_NO=${2} IMAGE=${IMAGE} TAG=${TAG} >>>>"

if TARGET=${TARGET} DOMAIN=${DOMAIN} NAMESPACE=${1} IMAGE=${IMAGE} TAG=${TAG} ./compile.sh ; then
    echo "Compile succeeded"
else
    echo "Compile failed"
    exit 1
fi 
}


# deploy manifest only on-demand instance
deployManifest(){
echo ${AWS_DEFAULT_REGION}
echo ${INPUT_AWS_ACCESS_KEY_ID}
aws configure set region ${AWS_DEFAULT_REGION}
aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
aws configure set role_arn "arn:aws:iam::${AWS_ORG_ID}:role/adminAssumeRole"
aws configure set source_profile default
aws eks update-kubeconfig --role-arn "arn:aws:iam::${AWS_ORG_ID}:role/adminAssumeRole" --name="${AWS_EKS_CLUSTER_NAME}"  --kubeconfig /kubeconfig --profile default
export KUBECONFIG=/kubeconfig
echo ">>>> kubeconfig created"

echo ">>> deployement start Cluster:${1}, namespace: ${2}"
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
            targetRevision: ${TARGET_BRANCH}
          syncPolicy:
            automated: {}
EOF
}


if [[ ${ON_DEMAND_INSTANCE} = 'true' ]];  then
  compileManifest alpha
else  
  clusters=`cat ./environments/${TARGET}/${TARGET}.json`
  for row in $(echo "${clusters}" | jq -r '.[] | @base64'); do
      environment=$(getValue ${row} '.environment')
      cluster=$(getValue ${row} '.cluster')
      echo "<<<< Auto deploy Cluester=${cluster} RELEASE_NO=${RELEASE_NO} RC_NO=${RC_NO} Environment=${environment} >>>>"
      compileManifest ${environment} 
  done
fi  

git add -A
          
## If there is nothing to commit exit without fail to continue
# this will happan if you running a deployment manually for a specific commit 
# so there will be no changes in the compiled manifests since no new docker image created

git commit -am " Image: ${IMAGE}  TAG=${TAG} &  Recompiled manifests"


git checkout  ${TARGET_BRANCH}
git rebase -Xours ${SOURCE_BRANCH}
echo ">>> git push --set-upstream origin ${TARGET_BRANCH}"
git push --set-upstream origin ${TARGET_BRANCH}

if [[ ${ON_DEMAND_INSTANCE} = 'true' ]];  then
  deployManifest alpha ${NAMESPACE}
fi

echo ">>> Completed"

