# Container image that runs your code
FROM bluescape/jsonnet-ci

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /entrypoint.sh

#git updated with latest version 
#todo need to move base image 
# RUN echo "deb http://ftp.us.debian.org/debian testing main contrib non-free" >> /etc/apt/sources.list \
#          &&      apt-get update              \
#          &&      apt-get install -y git      \
#          &&      apt-get clean all


# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]
