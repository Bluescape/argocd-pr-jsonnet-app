#!/bin/bash

GITHUB_PAT=${1}
ORG=${2}
INFRA_REPO=${3}
PR_REF=${4}
IMAGE=${5}
SHA=${6}
AWS_ACCESS_KEY_ID=${7}
AWS_SECRET_ACCESS_KEY=${8}
AWS_DEFAULT_REGION=${9}
AWS_ORG_ID=${10}
AWS_EKS_CLUSTER_NAME=${11}


SOURCE_BRANCH=master
TARGET_BRANCH=alpha
IMAGE_BRANCH=alpha

REGEX="[a-zA-Z]+-[0-9]{1,5}"
export ON_DEMAND_INSTANCE=false
export TARGET=dev

# Tag for release RC tag
if [[ ${PR_REF} =~ ^refs/tags/*.*.*$ ]] then 
  export SOURCE_BRANCH=release
  export TARGET_BRANCH=preprod
  export IMAGE_BRANCH=release
  export TARGET=preprod
  RELEASE_NO_TAG=${PR_REF#refs/*/}
  if [[ ${IMAGE} ]];  then
    export TAG="${SHA}-release-${RELEASE_NO_TAG}"
  fi
# Deploy to staging if branch is develop, main or master
# Note: infrastrucure branch is using master  
elif [[ ${PR_REF} =~ ^refs/heads/(master|develop|main)$ ]]; then
  export SOURCE_BRANCH=master
  export TARGET_BRANCH=alpha
  export IMAGE_BRANCH=alpha
  export TARGET=dev
  if [[ ${IMAGE} ]];  then
    export TAG="${SHA}"
  fi
# checking if this is a feature branch or release
elif [[ ${PR_REF} =~ ${REGEX} ]]; then
  # If branch does not exist create it
  export SOURCE_BRANCH=${PR_REF}
  export TARGET_BRANCH=${PR_REF}
  export IMAGE_BRANCH=${PR_REF}
  export TARGET=dev
  export ON_DEMAND_INSTANCE=true
  if [[ ${IMAGE} ]];  then
    export TAG="${SHA}"
  fi
  # set namespace as jira issue id extracted from branch name and make sure it is lowercase
  export NAMESPACE=$(echo ${BASH_REMATCH[0]} |  tr '[:upper:]' '[:lower:]')
else
  echo "<<<< ${PR_REF} cannot be deployed, it is not a feature branch nor a release,develop"
  exit 1
fi


echo "<<<< TARGET:${TARGET} IMAGE:${IMAGE} PR_REF:{$PR_REF} TAG:${TAG}"
echo "<<<< Cloning infrastructure repo ${ORG}/${INFRA_REPO}"
git clone https://${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}.git 
cd ${INFRA_REPO}

git config --local user.name "GitHub Action"
git config --local user.email "action@github.com"
git remote set-url origin https://x-access-token:${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}
git fetch --all

updateImage(){
  echo "Image update Image: ${IMAGE}, Tag: ${TAG}"
  if IMAGE=${IMAGE} TAG=${TAG} ./update_image.sh ; then
    echo "Image update succeeded"
else
    echo "Image update failed"
    exit 1
fi 
}

compileManifest(){
echo ">>>> Compiling manifests for"
echo "ref ${PR_REF}"
echo "cluster ${CLUSTER}"
echo "namespace ${1}"

echo "<<<< Compile manifest Cluester=${1} RELEASE_NO=${2} IMAGE=${IMAGE} TAG=${TAG} >>>>"

if ON_DEMAND_INSTANCE=${ON_DEMAND_INSTANCE} TARGET=${TARGET} NAMESPACE=${1} IMAGE=${IMAGE} TAG=${TAG} ./compile.sh ; then
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
            path: jsonnet/${ORG}/environments/dev/${1}/manifests
            repoURL: git@github.com:${ORG}/${INFRA_REPO}.git
            targetRevision: ${TARGET_BRANCH}
          syncPolicy:
            automated: {}
EOF
}

getValue(){
  echo ${1} | base64 --decode | jq -r ${2}
}


#update image for all cluster 

cd jsonnet/${ORG}
if [[ ${SOURCE_BRANCH} = 'release' ]];  then
  echo "Checkout Source Branch : ${SOURCE_BRANCH}"
  git checkout ${SOURCE_BRANCH} || git checkout -b ${SOURCE_BRANCH}
  updateImage
  git add -A
  git commit -am " Image: ${IMAGE}  TAG=${TAG} Image updated"

  echo ">>> git push --set-upstream origin ${SOURCE_BRANCH}"
  git push --set-upstream origin ${SOURCE_BRANCH}
fi


echo "Checkout Target Branch : ${TARGET_BRANCH}"
git checkout ${TARGET_BRANCH} || git checkout -b ${TARGET_BRANCH}
echo "Rebase with ${SOURCE_BRANCH}"
git rebase  ${SOURCE_BRANCH}

if [[ ${ON_DEMAND_INSTANCE} = 'true' ]];  then
    compileManifest ${NAMESPACE}
else
    clusters=`cat ./environments/${TARGET}/${TARGET}.json`
    for row in $(echo "${clusters}" | jq -r '.[] | @base64'); do
        environment=$(getValue ${row} '.environment')
        cluster=$(getValue ${row} '.cluster')
        echo "<<<< Auto deploy Cluester=${cluster} Environment=${environment} >>>>"
        compileManifest ${environment} 
    done
  fi
  git add -A
  git commit -am " Image: ${IMAGE}  TAG=${TAG} &  Recompiled manifests"
  echo ">>> git push --set-upstream origin ${TARGET_BRANCH}"
  git pull --rebase
  git push --set-upstream origin ${TARGET_BRANCH}
fi    


# deployment call only for ondemand instance (alpha)
if [[ ${ON_DEMAND_INSTANCE} = 'true' ]];  then
  deployManifest alpha ${NAMESPACE}
fi

echo ">>> Completed"

