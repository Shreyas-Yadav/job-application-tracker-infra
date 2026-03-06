# Deploying a Full-Stack Web Application to AWS with Nightly CI/CD

**Author:** Shreyas Yadav
**Application:** Job Application Tracker
**Live URL:** https://shri.software
**Source Repo:** https://github.com/Shreyas-Yadav/job-application-tracker
**Infra Repo:** https://github.com/Shreyas-Yadav/job-application-tracker-infra

---

## 1. Architecture Overview

The Job Application Tracker is a full-stack web application that allows users to track their job applications with features like adding, editing, filtering, and deleting entries.

### Tech Stack
- **Frontend:** Next.js 14 with React and Tailwind CSS
- **Backend:** Node.js with Express
- **Database:** MySQL 8 (local: Docker container, production: AWS RDS)
- **Orchestration:** Docker Compose
- **CI/CD:** GitHub Actions (nightly build pipeline)
- **Infrastructure:** AWS EC2, ECR, RDS, Route53
- **SSL:** Let's Encrypt via Certbot
- **Reverse Proxy:** Nginx

### Architecture Diagram

```
[GitHub Actions - Nightly Trigger]
        |
        v
  1. Build Docker images
  2. Push to ECR (timestamp tag)
        |
        v
  3. Smoke Test on Temp EC2 (via SSM)
     - Pulls images from ECR
     - Runs docker-compose.smoke.yml
     - Curls /health, /api/applications, frontend
     - Terminates temp EC2 (always)
        |
        v
  4. Promote: retag timestamp -> :latest in ECR
        |
        v
  5. Deploy to QA EC2 (via SSM)
     - Pulls :latest from ECR
     - docker compose up -d
     - Health check
        |
        v
  [https://shri.software] <-- Route53 + Nginx + Let's Encrypt
```

### Two-Repo Strategy

The project uses two separate repositories:

- **Source Repo (`job-application-tracker`):** Contains the application code — frontend, backend, Dockerfiles, and smoke test scripts. This is where developers work.
- **Infra Repo (`job-application-tracker-infra`):** Contains the deployment pipeline — GitHub Actions workflows, production Docker Compose files, Nginx configuration, and smoke test compose files. This separates deployment concerns from application development.

---

## 2. Local Development with Docker Compose

The application runs locally using Docker Compose with three services: frontend, backend, and MySQL.

### Project Structure

```
job-application-tracker/
├── frontend/           # Next.js app
│   ├── Dockerfile      # Multi-stage build, non-root user
│   └── src/
├── backend/            # Express API
│   ├── Dockerfile      # Non-root user
│   └── src/
├── docker-compose.yml  # Local dev (includes MySQL)
├── .env.example        # Template for environment variables
├── .gitignore
└── tests/
    └── smoke.sh        # Local smoke test script
```

### Running Locally

```bash
cp .env.example .env    # Fill in your values
docker compose up --build
```

- Frontend: http://localhost:3000
- Backend: http://localhost:5000
- Health Check: http://localhost:5000/health

### Production-Hardened Dockerfiles

Both Dockerfiles follow security best practices:

**Backend Dockerfile** — runs as non-root user `shri`:
```dockerfile
FROM node:20-alpine
RUN addgroup -S shri && adduser -S shri -G shri
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY src/ ./src/
RUN chown -R shri:shri /app
USER shri
EXPOSE 5000
CMD ["node", "src/index.js"]
```

**Frontend Dockerfile** — multi-stage build with non-root user:
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json .
RUN npm install
COPY . .
RUN npm run build

FROM node:20-alpine
RUN addgroup -S shri && adduser -S shri -G shri
WORKDIR /app
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
RUN chown -R shri:shri /app
USER shri
EXPOSE 3000
CMD ["npm", "start"]
```

The multi-stage build keeps the final image small by discarding build tools and source files. Only the compiled output is copied to the runtime stage.

---

## 3. AWS Infrastructure Setup

All AWS resources were provisioned manually (no IaC) as per assignment requirements.

### 3a. ECR Repositories

Two ECR repositories store the Docker images:
- `job-tracker-backend`
- `job-tracker-frontend`

Images are tagged with timestamps (e.g., `20260306055858`) during builds, then promoted to `:latest` after passing smoke tests.

### 3b. Security Groups

Three security groups control network access:

| Security Group | Inbound Rules | Purpose |
|---|---|---|
| `sg-qa` | Port 80 (HTTP), 443 (HTTPS) from 0.0.0.0/0 | QA EC2 — serves the live app |
| `sg-temp` | None (SSM only, no inbound needed) | Temp EC2 — smoke testing |
| `sg-rds` | Port 3306 from `sg-qa` only | RDS — database access restricted to QA EC2 |

### 3c. Pre-baked AMI

Instead of installing Docker on every temp EC2 launch (which takes 3-5 minutes), a custom AMI was created with everything pre-installed:
- Docker
- Docker Compose plugin
- AWS CLI
- SSM Agent
- Git

This reduces temp EC2 boot-to-ready time to about 60 seconds.

### 3d. QA EC2 (Permanent)

The QA EC2 is the production server:
- Instance type: `t3.micro`
- AMI: Custom pre-baked AMI
- IAM Role: `LabRole` (for ECR access and SSM)
- Elastic IP: `54.83.57.157` (prevents IP change on reboot)
- Software: Docker, Docker Compose, Nginx, Certbot, AWS CLI

### 3e. RDS MySQL

- Engine: MySQL 8.0
- Instance: `db.t3.micro`
- Database name: `jobtracker`
- Not publicly accessible — only reachable from `sg-qa`

---

## 4. Nightly CI/CD Pipeline

The pipeline is defined across multiple reusable workflow files in the infra repo for maintainability.

### Pipeline Flow

```
setup → build → smoke-test → promote → deploy-qa
```

### Workflow Files

```
.github/workflows/
├── nightly.yml          # Orchestrator — triggers at 2 AM UTC daily
├── build.yml            # Builds images, pushes to ECR with timestamp tag
├── smoke-test.yml       # Launches temp EC2, runs docker compose smoke test
├── promote.yml          # Retags timestamp → :latest in ECR
└── deploy-qa.yml        # Deploys to QA EC2 via SSM
```

### Job 1: Build & Push to ECR (`build.yml`)

- Checks out the source repo
- Builds backend and frontend Docker images
- Pushes to ECR with a timestamp tag (e.g., `20260306055858`)
- Images are NOT tagged as `:latest` yet — they must pass smoke tests first

### Job 2: Smoke Test on Temp EC2 (`smoke-test.yml`)

This is the most complex job:

1. **Launch temp EC2** from the pre-baked AMI with SSM access
2. **Wait for SSM** to come online (polls every 10s)
3. **Start services via SSM** — sends commands to:
   - Login to ECR
   - Clone the infra repo (to get `docker-compose.smoke.yml`)
   - Run `docker compose up` with MySQL + backend + frontend
4. **Run smoke tests** — curls `/health`, `/api/applications`, and the frontend
5. **Terminate temp EC2** — runs with `if: always()` to ensure cleanup even on failure

The smoke test uses `docker-compose.smoke.yml` which includes a local MySQL container with health checks, ensuring the backend only starts after the database is ready.

### Job 3: Promote to Latest (`promote.yml`)

Only runs if smoke tests pass. Uses the ECR API to retag the timestamp-tagged images as `:latest`:

```bash
MANIFEST=$(aws ecr batch-get-image --repository-name $REPO \
  --image-ids imageTag=$IMAGE_TAG --query 'images[0].imageManifest' --output text)
aws ecr put-image --repository-name $REPO --image-tag latest --image-manifest "$MANIFEST"
```

This is a metadata-only operation — no image data is copied.

### Job 4: Deploy to QA EC2 (`deploy-qa.yml`)

Uses SSM to run commands on the QA EC2:
1. Login to ECR
2. Pull latest images via `docker compose pull`
3. Restart services via `docker compose up -d`
4. Health check to verify deployment

### SSM vs SSH

The entire pipeline uses **AWS Systems Manager (SSM)** instead of SSH:
- No SSH keys to manage or rotate
- No port 22 needed in security groups
- Commands are logged and auditable
- Works through IAM roles — no credential distribution needed

### Key Design Decision: Push Before Test

Images are pushed to ECR *before* smoke testing (with timestamp tags only). If tests fail, `:latest` is never updated, so the QA EC2 continues running the last known-good version. This avoids the complexity of transferring Docker image tarballs to the temp EC2.

---

## 5. Domain Setup via Route53

1. **Created a Hosted Zone** in Route53 for `shri.software`
2. **Updated nameservers** at the domain registrar (name.com) to point to Route53's NS records
3. **Created an A record** pointing `shri.software` to the Elastic IP `54.83.57.157`

DNS propagation took approximately 15 minutes.

---

## 6. SSL with Let's Encrypt + Nginx

### Nginx as Reverse Proxy

Nginx listens on ports 80 and 443 and forwards traffic:
- `/api/*` → backend on port 5000
- `/*` → frontend on port 3000

### SSL Certificate

SSL was configured using Certbot with the Nginx plugin:

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d shri.software
```

Certbot automatically:
- Obtains a free SSL certificate from Let's Encrypt
- Configures Nginx with HTTPS
- Sets up HTTP → HTTPS redirect
- Configures automatic certificate renewal (every 90 days)

---

## 7. End-to-End Verification

### Pipeline Verification
1. Trigger workflow via `workflow_dispatch` in GitHub Actions
2. All 5 jobs complete successfully: setup → build → smoke-test → promote → deploy-qa
3. New images appear in ECR with both timestamp and `:latest` tags
4. Temp EC2 is launched and terminated automatically

### Application Verification
- `https://shri.software` — loads the Job Application Tracker with valid SSL
- `https://shri.software/api/applications` — returns JSON array from RDS
- `https://shri.software/api/applications` — supports full CRUD operations

### Security Verification
- Docker containers run as non-root user `shri`
- RDS is not publicly accessible
- No SSH keys or port 22 in use — all management via SSM
- SSL certificate valid and auto-renewing
- `.env` files excluded from version control

---

## 8. Lessons Learned

1. **Pre-baked AMIs save significant time** — Installing Docker on each temp EC2 takes 3-5 minutes. A custom AMI reduces this to ~60 seconds.

2. **SSM is superior to SSH for automation** — No key management, no open ports, and built-in logging. The tradeoff is slightly more complex command execution (JSON escaping in SSM commands).

3. **Two-repo separation works well** — App developers can push code without touching deployment configs, and infra changes don't trigger unnecessary app builds.

4. **Reusable GitHub Actions workflows improve maintainability** — Breaking a 200-line workflow into 5 focused files makes debugging and updating much easier.

5. **Push-before-test with tag promotion is elegant** — Pushing images to ECR before testing (with timestamp tags) avoids file transfer complexity. The `:latest` tag acts as a promotion gate.

6. **AWS Academy credential expiry is a real constraint** — Session tokens expire every ~4 hours, requiring manual refresh of GitHub Secrets before each pipeline run.
