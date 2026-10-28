# Quiz — AWS ECS Fargate

5 questions. Try them before opening the answers.

## 1. What is the main difference between the ECS execution role and the task role?

<details>
<summary>Answer</summary>

The **execution role** lets ECS itself pull your image from ECR and write
logs — it acts before your code starts. The **task role** is your
application's identity: what your code can call (S3, DynamoDB, SQS…).
Scope the task role tightly; widening the execution role never gives your
app extra permissions.
</details>

## 2. Why should Fargate tasks live in private subnets?

<details>
<summary>Answer</summary>

So they have no public IP and cannot be reached directly from the internet.
Inbound traffic comes only through the ALB, whose security group is the
only source allowed in the task security group. Outbound AWS API calls go
via VPC endpoints or a NAT gateway.
</details>

## 3. True or false: Fargate scales a service to zero automatically when traffic stops.

<details>
<summary>Answer</summary>

**False.** ECS Service Auto Scaling scales between the min and max you
set, but it does not scale to zero on its own. A service with
`desired_count = 1` bills 24/7. For scale-to-zero you need a pattern built
around it (e.g. SQS queue depth driving the service, or Lambda instead).
</details>

## 4. A task requests 1 vCPU / 2 GB but consistently uses 0.1 vCPU / 0.4 GB. What is wrong?

<details>
<summary>Answer</summary>

It is over-provisioned, and Fargate bills requested — not used — capacity.
Right-size it (e.g. 0.25 vCPU / 0.5 GB), verify with CloudWatch Container
Insights, then let autoscaling handle peaks instead of paying for idle
capacity all day.
</details>

## 5. When is Fargate Spot a bad choice?

<details>
<summary>Answer</summary>

For user-facing, latency-sensitive services: Spot tasks can be interrupted
with short notice. Spot (up to ~70% cheaper) fits batch jobs, workers, and
anything that tolerates interruption and retries — not your checkout API.
</details>
