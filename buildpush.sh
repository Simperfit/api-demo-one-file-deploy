#!/usr/bin/env bash

# Choose the CI you want to run the deployments.
# Both CI will make tests but only the one specified will deploy.
# Current available choices are travis and circleci.
export CURRENT_CI=zaza
export NAMESPACE=zaza
# If you don't want to deploy feature branches, set FEATURE_DEPLOY value to 0.
export FEATURE_DEPLOY=1

export RELEASE=zaza
# The project git repository.
export REPOSITORY=api-platform/demo
export DOCKER_REPOSITORY=simperfit
# Choose the branch for production deploy.
export DEPLOYMENT_BRANCH=master

# Configure your domain.
export DOMAIN=testformation.local

# Configure your sub-domains for: api, mercure, admin, client.
export API_SUBDOMAIN=demo
export MERCURE_SUBDOMAIN=demo-mercure
export ADMIN_SUBDOMAIN=demo-admin
export CLIENT_SUBDOMAIN=demo-client

# Miscellaneous
export CORS_ALLOW_ORIGIN=^https?://.*?\\.api-platform\\.com$
export TRUSTED_HOSTS=^.*\\.api\\-platform\\.com$

export PHP_REPOSITORY=docker.io/simperfit/php
export NGINX_REPOSITORY=docker.io/simperfit/nginx
export VARNISH_REPOSITORY=docker.io/simperfit/varnish
export TAG=zaza

# Build and push the docker images.
#docker build --pull -t $PHP_REPOSITORY:$TAG api --target api_platform_php
#docker build --pull -t $NGINX_REPOSITORY:$TAG api --target api_platform_nginx
#docker build --pull -t $VARNISH_REPOSITORY:$TAG api --target api_platform_varnish
#docker push $PHP_REPOSITORY:$TAG
#docker push $NGINX_REPOSITORY:$TAG
#docker push $VARNISH_REPOSITORY:$TAG

# To enable blackfire, set the BLACKFIRE_SERVER_ID and BLACKFIRE_SERVER_TOKEN variables.
if [[ ! -z $BLACKFIRE_SERVER_ID && ! -z $BLACKFIRE_SERVER_TOKEN ]]; then
    export BLACKFIRE_ENABLED=true
fi

# Generate random key & jwt for Mercure if not set
if [[ -z $MERCURE_JWT_KEY ]]; then
    #sudo npm install --global "@clarketm/jwt-cli"
    export MERCURE_JWT_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    export MERCURE_JWT=$(sudo jwt sign --noCopy '{"mercure": {"publish": ["*"]}}' $MERCURE_JWT_KEY)
fi

# Generate random database password if not set
if [[ -z $DATABASE_PASSWORD ]]; then
    export DATABASE_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
fi

export PROJECT_NAME=`echo $REPOSITORY | sed -E "s/\//-/g" | sed -e 's/\(.*\)/\L\1/'`
export PHP_REPOSITORY="${DOCKER_REPOSITORY}/php"
export NGINX_REPOSITORY="${DOCKER_REPOSITORY}/nginx"
export VARNISH_REPOSITORY="${DOCKER_REPOSITORY}/varnish"
if [[ $BRANCH == $DEPLOYMENT_BRANCH ]]
then
    export TAG=latest
    export API_ENTRYPOINT="${API_SUBDOMAIN}.${DOMAIN}"
    export MERCURE_ENTRYPOINT="${MERCURE_SUBDOMAIN}.${DOMAIN}"
    export ADMIN_BUCKET="${ADMIN_SUBDOMAIN}.${DOMAIN}"
    export CLIENT_BUCKET="${CLIENT_SUBDOMAIN}.${DOMAIN}"
else
    export TAG=$RELEASE
    export API_ENTRYPOINT="${API_SUBDOMAIN}-${RELEASE}.${DOMAIN}"
    export MERCURE_ENTRYPOINT="${MERCURE_SUBDOMAIN}-${RELEASE}.${DOMAIN}"
    export ADMIN_BUCKET="${ADMIN_SUBDOMAIN}-${RELEASE}.${DOMAIN}"
    export CLIENT_BUCKET="${CLIENT_SUBDOMAIN}-${RELEASE}.${DOMAIN}"
fi

    helm delete --purge $RELEASE || echo "No release to purge"
    kubectl delete namespace $NAMESPACE --wait --cascade || echo "No namespace to purge"

    # Create namespace with kubernetes to add labels on it
    cat <<EOF | kubectl create -f -
{
  "kind": "Namespace",
  "apiVersion": "v1",
  "metadata": {
	"name": "$NAMESPACE",
	"labels": {
		"name": "$NAMESPACE",
		"project": "$PROJECT_NAME"
	}
  }
}
EOF

helm upgrade --install --reset-values --force --namespace=zaza --recreate-pods zaza ./api/helm/api \
    --set php.repository=$PHP_REPOSITORY,php.tag=$TAG \
    --set nginx.repository=$NGINX_REPOSITORY,nginx.tag=$TAG \
    --set varnish.repository=$VARNISH_REPOSITORY,varnish.tag=$TAG \
    --set blackfire.blackfire.server_id='' \
    --set blackfire.blackfire.server_token='' \
    --set blackfire.blackfire.enabled=false \
    --set php.mercure.jwt=$MERCURE_JWT \
    --set mercure.jwtKey=$MERCURE_JWT_KEY \
    --set postgresql.postgresqlPassword=$DATABASE_PASSWORD \
    --set ingress.hosts.api.host=$API_ENTRYPOINT \
    --set ingress.hosts.mercure.host=$MERCURE_ENTRYPOINT \
    --set mercure.subscribeUrl="https://${MERCURE_ENTRYPOINT}/hub" \
    --set external-dns.cloudflare.apiKey=$CF_API_KEY \
    --set external-dns.cloudflare.email=$CF_API_EMAIL \
    --set corsAllowOrigin=$CORS_ALLOW_ORIGIN \
    --set mercure.corsAllowOrigin=$CORS_ALLOW_ORIGIN \
    --set trustedHosts=$TRUSTED_HOSTS \
    --set mercure.domainFilters="{$DOMAIN}"

kubectl exec --namespace=$NAMESPACE -it $(kubectl --namespace=$NAMESPACE get pods -l app=api-php -o jsonpath="{.items[0].metadata.name}") \
    -- sh -c 'APP_ENV=dev composer install -n && bin/console d:s:u --force -e prod && bin/console h:f:l -n -e dev && APP_ENV=prod composer --no-dev install --classmap-authoritative && exit 0'

sudo kubectl port-forward -n zaza service/nginx 80
#sudo minikube start --vm-driver=none --extra-config=kubelet.resolv-conf=/var/run/systemd/resolve/resolv.conf