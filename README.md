
# GeoServer Cloud (Public)

## Project Overview
GeoServer Cloud (Public) provides a scalable, cloud-native platform for serving and managing geospatial data using GeoServer Cloud, PostgreSQL/PostGIS, and supporting tools. Designed for deployment on the BCGov OpenShift Environment, it enables secure, high-performance spatial data services for public and internal use.

## Architecture
#### Technology Stack:
- **Nginx**: An externally exposed reverse proxy providing rate limiting and caching in front of GeoServer.
- **GeoServer Cloud**: A high-performance platform for transforming and sharing geospatial data.
- **PostgreSQL / PostGIS (via Crunchy)**: A robust, clustered object-relational database system with advanced geospatial capabilities.
- **RabbitMQ**: A message broker facilitating communication between GeoServer Cloud microservices.
- **PGAdmin Web**: An optional web-based tool for monitoring and managing PostgreSQL databases.

#### Databases:
- **ogs_configuration**: Central configuration database for GeoServer Cloud. All microservices (e.g., webui, wfs) connect here for shared settings and service discovery.
- **gisdata**: Primary geospatial data store. Contains all spatial datasets managed and served by GeoServer Cloud.

#### Database User Accounts:
- **postgres**: Superuser for administering the PostgreSQL cluster.
- **ogs-config-user**: Application user for GeoServer Cloud to access the ogs_configuration database.
- **ogs-ro-user**: Read-only user for accessing data in the gisdata database.
- **ogs-rw-user**: Read-write user for managing and updating data in the gisdata database.

## Build/Deployment
#### Requirements:
- Shell environment via native Linux or WSL
- Git Version Control ([git-scm.com](https://git-scm.com/install/))
- OpenShift CLI ([download instructions](https://developers.redhat.com/learning/learn:openshift:download-and-install-red-hat-openshift-cli/resource/resources:download-and-install-oc))
  - Ensure your user account has sufficient permissions to create secrets, deploy workloads, and manage PVCs.

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
# Create GeoServer Secrets (use strong, unique passwords)
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
To allow PgAdmin and the DB Backup CronJobs to access the database, apply the following YAML in each project (e.g., abc123-dev, abc123-test, or abc123-prod). Replace `[tools-project-id]` with your tools project name (e.g., abc123-tools).

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
> **Note:** NetworkPolicies restrict access to your database pods. Only allow trusted namespaces.

#### 2. Switch to Tools Project:
```bash
oc project <tools-project-id>
```

#### 3. Add Secrets (use strong, unique passwords):
```bash
oc create secret generic ogs-pgadmin \
  --from-literal=PGADMIN_EMAIL=admin@example.com \
  --from-literal=PGADMIN_PASSWORD=***password***
```

#### 4. Deploy PgAdmin:
```bash
./scripts/manage-pgadmin.sh deploy
  - Review and confirm with 'Y'
```

#### 5. Deploy Database Backup CronJobs per Project
Replace [target-project-id] with the name of your Project you wish to run the database backup for (i.e. abc123-dev, abc123-test, or abc123-prod). Requires ogs-cronjob-schedules secret in each target project.
```bash
./scripts/manage-cronjob-db-backup.sh deploy [target-project-id]
  - Review and confirm with 'Y'
```

## Start adding tables, data, layers, security, etc.

The following endpoints are available to build your own custom setup:
- **GeoServer Web UI:** `https://ogs-[project-name].apps.silver.devops.gov.bc.ca/`
- **RabbitMQ Management:** `https://ogs-[project-name].apps.silver.devops.gov.bc.ca/rabbitmq/`
- **PgAdmin Web:** `https://ogs-[tools-project-name].apps.silver.devops.gov.bc.ca/pgadmin/`

User account details are available as secrets within:
- ogs-postgresql-cluster-pguser-ogs-ro-user
- ogs-postgresql-cluster-pguser-ogs-rw-user
- ogs-postgresql-cluster-pguser-postgres

## Notes

- Deployment order is critical, as some components rely on resources created by others.
- The database backup cronjob writes its database dump files to PgAdmin's Persistent Volume Claim (PVC).
- The PgAdmin deployment is not required for normal operation, but is useful for database management and backup retrieval.
- The database backup cronjob can be disabled by removing the ogs-cronjob-schedules secret.

## Tips & Tricks

- To scale down all deployments (for cost savings):
  ```bash
  oc scale deployment --replicas=0 -l app.kubernetes.io/part-of=ogs-public
  ```
- To scale back up, set `--replicas` to the desired number.
- To remove all deployments and resources, use the `remove` action in the management scripts.
- To check logs for troubleshooting:
  ```bash
  oc logs deployment/<deployment-name>
  ```
- If you encounter permission errors, verify your OpenShift user role and project context.
- For secret or PVC issues, ensure the resources exist and are correctly referenced in your deployment YAML.
- Use PgAdmin's Storage Manager to view or download backups.

## Removal / Cleanup

*** WARNING:  YOU WILL LOSE DATA ***

- To remove all GeoServer Cloud components:
  ```bash
  ./scripts/manage-geoserver.sh remove
  ./scripts/manage-rproxy.sh remove
  # Confirm removal when prompted
  ```
- To remove the Crunchy PostgreSQL cluster:
  ```bash
  oc delete -f k8s/postgres/cluster.yaml
  oc delete -f k8s/postgres/cluster-init.yaml
  ```
- Delete remaining PVCs as required (this will delete all data!):
  ```bash
  oc delete pvc --all
  ```
- **Warning:** Removing PVCs will permanently delete all database and backup data.

# License

This project is licensed under the terms of the [LICENSE](LICENSE) file in this repository.

