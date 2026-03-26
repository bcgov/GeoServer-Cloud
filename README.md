# GeoServer Cloud (Public)

This repository contains the required components to build a **Public Facing Spatial Service** using GeoServer Cloud, PostgreSQL, and PostGIS on the BCGov OpenShift Environment.

## Architecture
#### Technology Stack:
- **Nginx**: a rate limiting and caching reverse proxy exposed externally for GeoServer and PGAdmin Web.
- **GeoServer Cloud**: high performance server for transforming and sharing geospatial data.
- **PostgreSQL / PostGIS (via Crunchy)**: a powerful clustered object-relational database system enabled with geospatial functionality.
- **RabbitMQ**: a message broker that allows individual GeoServer Cloud microservices to communicate with each other.
- **PGAdmin Web**: a monitoring and management tool for PostgreSQL databases [optional].

#### Databases:
- **ogs_configuration**: a database that stores GeoServer Cloud configuration.  Each GeoServer microservice (webui, wfs, etc) connects to it.
- **gisdata**: a database that stores all your geospatial data.

#### Database User Accounts:
- **postgres**: the superuser for administering the postgresql cluster
- **ogs-config-user**: the user that GeoServer Cloud uses to connect to the ogs_configuration database.
- **ogs-ro-user**: a read-only user for the gisdata database.
- **ogs-rw-user**: a read-write user for the gisdata database.

## Build/Deployment
#### Requirements:
- Shell environment via native linux or WSL
- Git Version Control (https://git-scm.com/install/)
- OpenShift CLI (https://developers.redhat.com/learning/learn:openshift:download-and-install-red-hat-openshift-cli/resource/resources:download-and-install-oc)

#### 1. Clone the repo:
```bash
git clone https://github.com/vcschuni/ogs-public.git
cd ogs-public
```

#### 2. Login to OpenShift Cluster & Set the Project:
```bash
oc login --token=<token> --server=https://api.silver.devops.gov.bc.ca:6443
oc project <your-project-id>
```

#### 3. Add Secrets:
```bash
# Create GeoServer Secrets
oc create secret generic ogs-geoserver \
  --from-literal=GEOSERVER_ADMIN_USER=admin \
  --from-literal=GEOSERVER_ADMIN_PASSWORD=***password***

# Create RabbitMQ Secrets
oc create secret generic ogs-rabbitmq \
  --from-literal=RABBITMQ_DEFAULT_USER=admin \
  --from-literal=RABBITMQ_DEFAULT_PASS=***password***
  
# Create the CronJob Schedule (optional)
oc create secret generic ogs-cronjob-schedules \
  --from-literal=db_backup="0 6,18 * * *"
```

#### 4. Build Crunchy Cluster:

```bash
oc apply -f k8s/postgres/cluster-init.yaml
oc apply -f k8s/postgres/cluster.yaml
oc wait --for=condition=Ready postgrescluster/ogs-postgresql-cluster --timeout=20m
```

#### 5. Deploy Message Broker:

```bash	
./scripts/manage-rabbitmq.sh deploy
	- Review and confirm with 'Y'
```

#### 6. Deploy GeoServer Components:

You can do this by individual component (in order):
```bash
./scripts/manage-geoserver-webui.sh deploy
	- Review and confirm with 'Y'
	
./scripts/manage-geoserver-wfs.sh deploy
	- Review and confirm with 'Y'
	
./scripts/manage-geoserver-wms.sh deploy
	- Review and confirm with 'Y'
	
./scripts/manage-geoserver-rest.sh deploy
	- Review and confirm with 'Y'
	
./scripts/manage-geoserver-gateway.sh deploy
	- Review and confirm with 'Y'
```

or in one swoop:
```bash
./scripts/manage-geoserver.sh deploy
	- Review and confirm with 'Y'
```

#### 7. Deploy the Reverse Proxy:

```bash	
./scripts/manage-rproxy.sh deploy
	- Review and confirm with 'Y'
```

## * Optional (in TOOLS Project) *

#### 1. Create NetworkPolicies:

In each project (i.e. abc123-dev, abc123-test, or abc123-prod) that you want PgAdmin and the DB Backup CronJobs to have access to, apply the following YAML to create a NetworkPolicy.  You will need to replace [tools-project-id] with the name of your tools project (i.e. abc123-tools).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ogs-allow-tools-project-id
spec:
  podSelector:
    matchLabels:
      postgres-operator.crunchydata.com/cluster: ogs-postgresql-cluster
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: [tools-project-id]
    ports:
    - protocol: TCP
      port: 5432
```

#### 2. Switch to Tools Project:

```bash	
oc project <tools-project-id>
```

#### 4. Add Secrets:
```bash	
oc create secret generic ogs-pgadmin \
  --from-literal=PGADMIN_EMAIL=admin@example.com \
  --from-literal=PGADMIN_PASSWORD=***password***
```

#### 5. Deploy PgAdmin:
```bash	
./scripts/manage-pgadmin.sh deploy
	- Review and confirm with 'Y'
```
#### 6. Deploy Database Backup CronJobs per Project

Replace [target-project-id] with the name of your Project you wish to run the database backup for (i.e. abc123-dev, abc123-test, or abc123-prod). Requires ogs-cronjob-schedules secret in each target project.
```bash		
./scripts/manage-cronjob-db-backup.sh deploy [target-project-id]
	- Review and confirm with 'Y'
```

## Start adding tables, data, layers, security, etc.

The following endpoints are available to build your own custom setup:
- GeoServer WebUi: <a href="https://ogs-${PROJ}.apps.silver.devops.gov.bc.ca/">https://ogs-[project-name].apps.silver.devops.gov.bc.ca/</a>
- RabbitMQ Management:<a href="https://ogs-${PROJ}.apps.silver.devops.gov.bc.ca/rabbitmq/">https://ogs-[project-name].apps.silver.devops.gov.bc.ca/rabbitmq/</a>
- PgAdmin Web:<a href="https://ogs-${PROJ}.apps.silver.devops.gov.bc.ca/pgadmin/">https://ogs-[tools-project-name].apps.silver.devops.gov.bc.ca/pgadmin/</a>

User account details are available as secrets within:
- ogs-postgresql-cluster-pguser-ogs-ro-user
- ogs-postgresql-cluster-pguser-ogs-rw-user
- ogs-postgresql-cluster-pguser-postgres

## Notes

- Deployment order is critical as some components rely on the existence of resources created by other components.
- The database backup cronjob writes it's database dump files to PgAdmin's PVC.

## Tips & Tricks

- Scale the ogs-geoserver-webui & ogs-pgadmin deployments to 0 pods when not in use.  This improves security and reduces resource usage. 
- Use PgAdmin's Storage Manager to view/download backups. 

## Removal / Cleanup
To remove the database cluster, deployments, builds, etc. built and deployed above:

*** WARNING:  YOU WILL LOSE DATA ***

```bash
./scripts/manage-geoserver.sh remove
	- Review and confirm with 'Y'
	
./scripts/manage-rabbitmq.sh remove
	- Review and confirm with 'Y'
	
./scripts/manage-pgadmin.sh remove
	- Review and confirm with 'Y'
	
./scripts/manage-rproxy.sh remove
	- Review and confirm with 'Y'

oc delete postgrescluster ogs-postgresql-cluster
oc delete all,configmap,secret,pvc -l app=ogs-postgresql-cluster

Delete remaining PVC's as required
```

