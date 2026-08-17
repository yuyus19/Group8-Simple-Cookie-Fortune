# Reproduce

How to run Simple Fortune Cookie from a fresh checkout, and how to run the
same checks our pipeline runs.

All commands are written for Git Bash. There is a Makefile with shortcuts, but
`make` is not installed on Windows by default, so the plain commands below are
the ones we rely on.

## What you need

- Docker Desktop
- Go 1.20.14, which you can install with `./scripts/install-go.sh`
- kubectl, for the Kubernetes parts
- Helm, only for the Helm section

After installing Go, open a new terminal. On Windows quit VS Code completely
and reopen it, because its terminals keep the old PATH otherwise.

For Kubernetes you can either enable it in Docker Desktop under Settings, or
create a kind cluster with `kind create cluster --config k8s/kind-cluster.yaml`.
Check which one you are on with `kubectl config current-context`.

## Run it with Docker Compose

This is the quickest way to see the app working.

```bash
docker compose up -d --build --wait
```

Open <http://localhost:8080>.

To check it properly, run the smoke tests:

```bash
./scripts/smoke-test.sh
```

Six checks should pass. Stop everything with `docker compose down`.

If you would rather run the images our pipeline published instead of building
them yourself, use `docker compose pull` followed by
`docker compose up -d --no-build`.

## Run it on Kubernetes

`scripts/deploy.sh` handles the whole deployment. It picks the environment from
the branch name unless you set it yourself.

| Environment | Namespace | Frontend port |
| --- | --- | --- |
| production | `fortune` | 30080 |
| staging | `fortune-staging` | assigned automatically |
| development | `fortune-dev` | assigned automatically |

Only production keeps a fixed port, so that several environments can share one
cluster without clashing.

```bash
ENVIRONMENT=production ./scripts/deploy.sh
```

On Docker Desktop the app is then on <http://localhost:30080>. On kind it is on
<http://localhost:8081>, because `k8s/kind-cluster.yaml` maps the port across.
For any other environment, look up the port it was given:

```bash
kubectl -n fortune-dev get svc frontend -o jsonpath='{.spec.ports[0].nodePort}'
```

To deploy one specific build, pass the tag:

```bash
ENVIRONMENT=staging IMAGE_TAG=sha-1a2b3c4 ./scripts/deploy.sh
```

Going back a version is a rollout undo rather than a rebuild:

```bash
ENVIRONMENT=production ./scripts/rollback.sh --history
ENVIRONMENT=production ./scripts/rollback.sh
```

There is also a load test that runs siege in a container:

```bash
BASE_URL=http://localhost:30080 ./scripts/stress-test.sh
```

### Checking that the cookies survive

This is the point of the database exercise. Add a cookie through the page, then
restart the backend:

```bash
kubectl -n fortune rollout restart deploy/backend
```

The cookie is still there afterwards. It also survives deleting the Redis pod,
because Redis has a PersistentVolumeClaim.

## Run it with Helm

The chart turns our two almost identical Deployments into one template.

```bash
helm lint charts/fortune-cookie
helm upgrade --install fortune-cookie charts/fortune-cookie \
  --namespace fortune --create-namespace --wait
```

Values worth overriding are `image.tag`, `services.frontend.replicas` and
`redis.persistence.enabled`. Remove the release again with
`helm uninstall fortune-cookie --namespace fortune`.

Do not install the chart into the same namespace as `scripts/deploy.sh`. They
create the same object names and will overwrite each other.

## Prometheus and Grafana

```bash
kubectl apply -f k8s/monitoring/
```

Both are exposed as NodePorts, so there is no port forward to keep open.

- Grafana on <http://localhost:30300>, logging in with `admin` and `admin`
- Prometheus on <http://localhost:30090>

The dashboard is loaded automatically and splits every panel by namespace, so
each environment shows up separately. Queries we found useful:

```promql
max by (namespace) (fortune_cookies_stored)
sum by (namespace, handler) (rate(fortune_http_requests_total[1m]))
```

One thing worth knowing is that Prometheus only sees Kubernetes pods. It finds
them through the Kubernetes API, so a stack running under Docker Compose never
shows up even though those containers do expose `/metrics`.

## Running the tests yourself

These are the same checks CI runs:

```bash
for s in backend frontend; do
  (cd $s && gofmt -l . && go vet ./... && go test ./... && go build ./...)
done
```

With make installed, `make ci` does all of it in one go.

`golangci-lint` and Trivy are not installed locally. CI installs them itself,
so skipping them here is fine.

## The pipeline on GitHub

There are three workflows rather than one.

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `CI.yml` | PRs and pushes to `main` | builds, vets and tests on Ubuntu, Windows and macOS, and runs the linter |
| `publish.yml` | pushes to `main`, `ci/**` and `cd-**` | builds both images, scans them with Trivy, pushes them to Docker Hub, then pulls them back and runs them |
| `cd.yml` | pushes to `main` and `cd-**` | deploys to staging, smoke tests it, load tests it, and only then deploys production |

You can follow a run with `gh run list` and `gh run watch`, or start CD by hand
with `gh workflow run cd.yml`.

It uses three secrets. `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are needed to
push images, and `KUBECONFIG` is used to deploy to a real cluster. Without
`KUBECONFIG` the pipeline still works: it builds a temporary kind cluster inside
the runner, deploys there and deletes it at the end. That cluster has to be
reachable from the internet, so a kubeconfig for Docker Desktop or a local kind
cluster will not work from GitHub.
