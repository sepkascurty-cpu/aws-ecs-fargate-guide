# AWS ECS Fargate Guide — Serverless Containers, Done Right

![AWS](https://img.shields.io/badge/AWS-ECS%20Fargate-FF9900?style=for-the-badge&logo=amazonaws)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?style=for-the-badge&logo=terraform)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)
![Level](https://img.shields.io/badge/Level-Intermediate-blue?style=for-the-badge)

> **TL;DR:** Fargate lets you run containers without managing servers at all.
> You define *what* runs (task definition), *how many* (service), and *how it
> is reached (ALB)* — AWS handles the rest. This guide shows the production
> shape: private subnets, least-privilege task roles, ALB + target groups,
> CloudWatch logging, and service autoscaling that actually saves money.

## Why Fargate?

Running containers on EC2 means you pay for the host *and* babysit it:
patching, capacity planning, bin-packing, node failures. Fargate removes the
host from your job description. You pay per vCPU-second and GB-second your
tasks actually request — nothing for idle nodes, nothing for patching hosts.

| Question | EC2 launch type | Fargate launch type |
| --- | --- | --- |
| Who patches the host OS? | You | AWS |
| Who sizes the cluster? | You (ASG + bin-packing) | Nobody — per-task sizing |
| Billing | Per instance-hour, even idle | Per task vCPU + memory, per second |
| Best for | Long-lived, dense, GPU/special hosts | APIs, workers, bursty or spiky workloads |
| Control | Full (SSH, daemon sets, host tuning) | Task-level only (no host access) |

**Rule of thumb:** if you don't have a specific reason to touch the host,
start with Fargate. Move to EC2 only when you can name that reason
(GPU, huge steady-state density, privileged daemons).

## Architecture

![Architecture](architecture.svg)

Traffic flow, step by step:

1. **Client → Route 53 / ALB** — HTTPS terminates at the Application Load
   Balancer in public subnets.
2. **ALB → target group → Fargate tasks** — tasks live in *private* subnets;
   they have no public IP and cannot be reached directly from the internet.
3. **Tasks → AWS services** — via VPC endpoints (ECR, CloudWatch Logs,
   Secrets Manager) or a NAT gateway, never via a public IP on the task.
4. **Scaling** — ECS Service Auto Scaling reacts to ALB request count and
   CPU/memory, within the min/max you set. Scale-to-zero is *not* built in
   — keep `desired_count >= 1` for user-facing services, or front bursty
   jobs with SQS + a scale-to-zero pattern (see Pitfalls).

## Core concepts (one minute each)

### Task definition — the unit of deployment

A task definition is a JSON blueprint: container image, CPU/memory, port
mappings, environment variables, log configuration, and *two* IAM roles:

- **Execution role** — lets ECS pull your image from ECR and write logs.
  This is ECS acting *for you* before your code starts.
- **Task role** — what *your application code* can call (DynamoDB, S3, SQS…).
  Scope this one tightly; it is your app's identity.

Mixing them up is the #1 beginner mistake: a wide execution role does not
give your app permissions, and a wide task role does not help ECS pull images.

### Service — the desired state

A service keeps `desired_count` tasks healthy: it replaces crashed tasks,
rolls out new revisions, and (with CodeDeploy) can do blue/green deploys.
Pair it with an ALB target group and a health check path your app actually
implements (`/health`, not `/` if `/` is heavy).

### Capacity — right-size, then autoscale

Fargate bills the CPU/memory you *request*, not what you use. A task asking
for 1 vCPU / 2 GB but using 0.1 vCPU wastes 90% of its bill. Start small
(0.25 vCPU / 0.5 GB for a light API), measure with CloudWatch Container
Insights, then set autoscaling on CPU *and* ALB request count — CPU alone
misses I/O-bound or queue-bound saturation.

## Terraform quick start

`main.tf` in this repo provisions the full stack: VPC, public/private
subnets, ALB, ECS cluster, task definition, service, autoscaling, log group,
and least-privilege IAM roles.

```bash
terraform init
terraform plan   # read it — check the task CPU/memory and desired_count
terraform apply
```

Then verify:

```bash
aws ecs list-tasks --cluster demo-fargate --service-name api
aws ecs describe-services --cluster demo-fargate --services api \
  --query 'services[0].{running:runningCount,desired:desiredCount}'
curl -s https://<alb-dns-name>/health
```

Destroy when done — Fargate tasks bill while they run, even in a lab:

```bash
terraform destroy
```

## Security checklist

- [ ] Tasks in private subnets, no public IP (`assign_public_ip = false`)
- [ ] Security group allows inbound *only* from the ALB security group
- [ ] Task role scoped to exactly the tables/buckets/queues the app uses
- [ ] Secrets via Secrets Manager / SSM Parameter Store, never env vars in plain text
- [ ] Images scanned in ECR (scan on push) and pinned by digest in production
- [ ] `readonlyRootFilesystem = true` where the app allows it
- [ ] CloudWatch alarms on task failures, ALB 5xx, and target health

## Cost levers

| Lever | Saving | Trade-off |
| --- | --- | --- |
| Right-size CPU/memory | 30–70% vs. defaults | Requires measurement, not guessing |
| Fargate Spot for batch/workers | Up to 70% off | Tasks can be interrupted — never for user-facing APIs |
| Scale-in at night (scheduled scaling) | Proportional to idle hours | Only if traffic actually drops |
| Graviton (arm64) tasks | ~20% cheaper per vCPU | Image must build for arm64 |
| Fewer AZs for dev (1–2) | Halves NAT/ALB footprint | No production HA — dev only |

## Pitfalls (learned the expensive way)

1. **No scale-to-zero.** A service with `desired_count = 1` bills 24/7.
   For nightly jobs, use scheduled scaling or an SQS-driven pattern instead.
2. **NAT gateway bill shock.** Private subnets + NAT per AZ is ~$90/month
   before traffic. In dev, use one NAT or VPC endpoints for ECR/Logs/Secrets.
3. **Health check loops.** An app that returns 200 only after a slow warm-up
   gets killed and restarted forever. Set `healthCheckGracePeriodSeconds`
   generously (60–120s) and keep `/health` light.
4. **Logs that vanish.** Without `awslogs` configured, a crashed task's
   stdout is gone with the task. Always set a log group + retention.
5. **CPU/memory combos are fixed.** Fargate only allows valid pairs
   (e.g. 0.25 vCPU → 0.5–2 GB). `terraform plan` will tell you; check the
   table in the AWS docs before guessing.

## When NOT to use Fargate

- GPU workloads, or workloads needing host-level daemons (use EC2 / EKS).
- Extremely long-lived, high-density steady state where reserved EC2 wins
  on price — measure first, don't assume.
- Windows containers with special host requirements (check current support).

## Quiz

Test yourself in [quiz.md](quiz.md) — 5 questions with collapsed answers.

## Further reading

- AWS docs: Amazon ECS on Fargate — task definitions, services, networking
- AWS docs: Fargate valid CPU/memory combinations
- AWS docs: ECS Service Auto Scaling
