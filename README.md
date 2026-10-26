
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
git clone https://github.com/vcschuni/Geoserver-Cloud.git
cd Geoserver-Cloud
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
oc create secret generic ogs-tools-pgadmin \
  --from-literal=PGADMIN_EMAIL=admin@example.com \
  --from-literal=PGADMIN_PASSWORD=***password***
```

#### 4. Deploy PgAdmin:
```bash
./scripts/manage-tools-pgadmin.sh deploy
  - Review and confirm with 'Y'
```

#### 5. Deploy the Reverse Proxy:
```bash
./scripts/manage-tools-rproxy.sh deploy
  - Review and confirm with 'Y'
```

#### 6. Deploy Database Backup CronJobs per Project
Replace [target-project-id] with the name of your Project you wish to run the database backup for (i.e. abc123-dev, abc123-test, or abc123-prod). Requires ogs-cronjob-schedules secret in each target project.
```bash
./scripts/manage-tools-cronjob-db-backup.sh deploy [target-project-id]
  - Review and confirm with 'Y'
```

The deployment script creates the CronJob suspended, with scheduling settings and storage configured, and enables it only after credentials are successfully added. If setup fails, correct the error and rerun deployment; do not manually enable an incompletely configured CronJob.

The backup script attempts all databases and exits nonzero if any dump fails, so the Job reports failure. Dumps are written to `.partial` files and renamed to `.dump` only after successful completion. Retention cleanup runs only when all dumps succeed; otherwise existing backups are preserved.

## Start adding tables, data, layers, security, etc.

The following endpoints are available to build your own custom setup:
- **GeoServer Web UI:** `https://ogs-[project-name].apps.silver.devops.gov.bc.ca/`
- **RabbitMQ Management:** `https://ogs-[project-name].apps.silver.devops.gov.bc.ca/rabbitmq/`
- **PgAdmin Web:** `https://ogs-[tools-project-name].apps.silver.devops.gov.bc.ca/pgadmin/`

The public reverse proxy restricts `/web` and `/web/` child paths to client IP ranges `142.34.53.0/24`, `142.22.0.0/15`, `142.24.0.0/13`, and `142.32.0.0/13`; other clients receive HTTP 403. WMS/WFS paths remain unchanged. This is a network restriction, not user authentication, and does not restrict REST or RabbitMQ administration.

The restriction depends on trusted client-IP forwarding from the OpenShift router. The current Nginx configuration trusts `X-Forwarded-For` from `10.0.0.0/8`; validate the router's header handling and prevent untrusted direct access to the proxy before relying on this as an access boundary. Test `/web` and `/web/` from both allowed and disallowed networks, including a disallowed request with a forged allowed `X-Forwarded-For` address. Rebuild the proxy from the updated Git source to activate configuration changes.

User account details are available as secrets within:
- ogs-postgresql-cluster-pguser-ogs-ro-user
- ogs-postgresql-cluster-pguser-ogs-rw-user
- ogs-postgresql-cluster-pguser-postgres

## Restarting the Stack

To restart existing deployments without rebuilding images or applying version changes, run [restart-rollouts.sh](scripts/restart-rollouts.sh) from the repository root:

```bash
oc project <your-project-id>
bash scripts/restart-rollouts.sh
```

Review the selected project and restart order, then confirm with `Y`. The script checks that all seven deployments exist before requesting any restarts and waits for each rollout to finish in this order:

1. RabbitMQ
2. GeoServer WebUI
3. GeoServer WFS
4. GeoServer WMS
5. GeoServer REST
6. GeoServer Gateway
7. Reverse proxy

RabbitMQ restarts first so fresh GeoServer clients can recreate their subscriptions. The gateway and reverse proxy restart after the backends. Each deployment retains its existing rollout strategy.

**Warning:** This is not a zero-downtime operation. Replacing the single, non-persistent RabbitMQ broker interrupts connections and can lose broker state/messages. WebUI sessions and in-flight requests may also be affected. Do not use a full-stack restart when only an individual application needs restarting.

The script stops on the first failure or rollout timeout (10 minutes per deployment). Completed restarts are not undone, and an active rollout may continue after the script exits. After completion, verify WMS/WFS requests, the WebUI, and RabbitMQ queue consumers; pod readiness alone does not guarantee working event subscriptions.

## Troubleshooting

Search logs from all pods and containers in the currently selected OpenShift project for error-related keywords from the last 30 minutes:

```bash
oc get pods -o name | while IFS= read -r pod; do
    echo "=== ${pod} ==="
    oc logs "${pod}" \
        --all-containers=true \
        --prefix=true \
        --since=30m \
        --tail=-1 |
        grep -iE 'error|exception|fatal|panic'
done
```

Run this in Bash after selecting the project with `oc project <your-project-id>`. Adjust `--since=30m` as needed. This searches container stdout/stderr, not arbitrary log files inside containers, and keyword matches alone do not determine application health.

## Notes

- Deployment order is critical, as some components rely on resources created by others.
- The database backup cronjob writes its database dump files to PgAdmin's Persistent Volume Claim (PVC).
- The PgAdmin deployment is not required for normal operation, but is useful for database management and backup retrieval.
- The database backup cronjob can be disabled by removing the ogs-cronjob-schedules secret.

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
