FROM registry.fedoraproject.org/fedora:44

RUN update-ca-trust && dnf makecache --refresh && dnf install -y jq yq wget

# VERSION: 1.0.0