# Learning Guide: AWS Serverless Uptime Monitor

This guide assumes you know **nothing** about AWS, Terraform or CI/CD. Read it in order. By the end you will have:

- the project **running live** in your own AWS account,
- understood **every part** well enough to explain it in an interview.

**Suggested pace (about 2 weeks, 1–2 hours a day, alongside your AWS course):**

| Days | What to do |
|---|---|
| 1–2 | Part 1 (big picture) + Part 2 (concepts) |
| 3–4 | Part 4: deploy it (steps 1–6) |
| 5–7 | Part 3: read every file with this guide open |
| 8–10 | Part 4, step 7: make a change through a pull request; take screenshots |
| 11–14 | Part 5: practise the interview answers **out loud** |

---

## Part 1: The big picture (in simple words)

**What it does:** every 5 minutes, a small Python program wakes up, visits a list of websites, writes down "up or down + how fast", and goes back to sleep. A web page shows the results. If a site fails twice in a row, you get an email.

**What happens, step by step:**

1. **EventBridge** (an alarm clock in AWS) fires every 5 minutes.
2. It starts the **Lambda function** (our Python code, packaged as a **Docker image**).
3. The code checks each website (status code + response time).
4. It saves each result in **DynamoDB** (a database) and sends numbers to **CloudWatch** (AWS's monitoring service).
5. If the "sites down" number is ≥ 1 for two checks in a row, a **CloudWatch alarm** goes off and **SNS** sends you an email.
6. When someone opens the dashboard URL, **API Gateway** receives the request and calls the same Lambda function, which reads DynamoDB and returns the page or data.

**How the code gets to AWS (CI/CD):**

1. You `git push` to GitHub.
2. **GitHub Actions** automatically runs the tests, builds the Docker image and tests it.
3. If everything passes on the `main` branch, it logs in to AWS with the deploy user's access key (stored encrypted in GitHub Secrets), pushes the image to **ECR**, and runs **Terraform**, which creates or updates all the AWS resources.
4. Finally it calls `/health` on the live site to confirm the new version is running.

---

## Part 2: Every concept, explained simply

### AWS basics
- **Region:** a group of AWS data centers in one place. We use `eu-north-1` (Stockholm) because it is this account's **home region**: new AWS accounts on the Free plan can only create resources in one region. Where you live doesn't matter; anyone in the world can open the dashboard.
- **Free tier:** limited free usage each month. This project stays inside it.
- **ARN:** the unique "address" of any AWS resource, e.g. `arn:aws:lambda:eu-north-1:123456789012:function:uptime-monitor`.

### IAM (Identity and Access Management)
Controls **who can do what**. A **policy** is a JSON list of allowed actions on resources. A **role** is an identity that a service (or GitHub) can temporarily "wear" to get those permissions.
- **Least privilege:** give only the permissions really needed. Our Lambda can only write to *its* table, *its* log group and *its* metric namespace.

### Lambda
Runs your code **without a server**. You upload code; AWS runs it when an event arrives and charges per millisecond. Here, the code is packaged as a **container image**.
- **Cold start:** the first call after idle time is slower because AWS must start a new container.

### API Gateway (HTTP API)
Gives the Lambda a public **HTTPS URL**. We send every path (`$default` route) to Lambda, and the Python code decides what to return. **Throttling** (10 requests/second) protects against abuse.

### EventBridge
AWS's event bus and **scheduler**. A rule with `rate(5 minutes)` starts our Lambda every 5 minutes.

### DynamoDB
A fast **NoSQL database** (key-value). Our table's key:
- **Partition key** `url`: groups all checks of one website together
- **Sort key** `checked_at` (a timestamp): sorts them by time, so "the last 24 hours of github.com" is one fast query
- **TTL** (time to live): each item has an `expires_at` time, and DynamoDB deletes it automatically (free)
- **On-demand billing:** pay per request, nothing when idle

### CloudWatch
AWS's monitoring service:
- **Logs:** everything the Lambda prints
- **Metrics:** numbers over time. AWS creates some automatically (Lambda invocations, errors, duration), and we publish **custom metrics**: `Up`, `LatencyMs`, `SitesDown`.
- **Alarms:** watch a metric and change state (OK ↔ ALARM) when it crosses a threshold
- **Dashboards:** graphs of the metrics

### SNS (Simple Notification Service)
Sends messages to subscribers (email, SMS, other services). The alarm publishes to an SNS topic, and the topic emails you.

### Docker and ECR
- **Docker image:** a package with your code + everything it needs, so it runs the same everywhere.
- **Dockerfile:** the recipe for building the image. Ours starts from AWS's official Lambda Python image.
- **ECR (Elastic Container Registry):** AWS's private storage for Docker images. Lambda pulls our image from there.
- **Image tag = Git commit SHA:** every version can be traced back to the exact code.

### Terraform (Infrastructure as Code)
Instead of clicking in the AWS console, you **describe** the resources in `.tf` files, and Terraform creates them.
- `terraform init`: downloads the AWS provider and connects to the state storage
- `terraform plan`: shows what would change
- `terraform apply`: makes the changes
- `terraform destroy`: deletes everything
- **State:** a file where Terraform remembers what it created. We keep it in **S3**, so the pipeline can use it from anywhere. `use_lockfile = true` prevents two runs from changing it at the same time.
- **Why two folders?**
  - `bootstrap/` creates what the pipeline needs *before* it can run: the state bucket, the ECR repository and the GitHub login role. You run it once, by hand.
  - `app/` is everything else, and the pipeline applies it.

### Git, GitHub and CI/CD
- **Git:** tracks versions of your code. **GitHub:** hosts the repository online.
- **Branch / pull request (PR):** work on a copy (branch), then ask to merge it into `main`. The tests run on the PR before merging.
- **CI (Continuous Integration):** every change is automatically tested.
- **CD (Continuous Deployment):** every change merged to `main` is automatically deployed.
- **GitHub Actions:** GitHub's CI/CD tool. Our pipeline is `.github/workflows/pipeline.yml`.

### How GitHub logs in to AWS (access key vs OIDC)
The pipeline needs permission to change things in your AWS account. There are two ways to give it:

1. **Access key (what this project uses by default).** Terraform creates an IAM **user** called `github-deploy-uptime-monitor` with a **least-privilege** policy: it can only touch resources named `uptime-monitor*`. Its access key (an ID + a secret, like a username + password for programs) is stored in **GitHub Secrets**, which are encrypted and can't be read back, even by you.
   - Risk: a key never expires on its own, so if it leaked, someone could use it until you delete it. That's why it has minimal permissions and should be rotated from time to time.
2. **OIDC (OpenID Connect).** The more modern way, with no stored keys:
   1. GitHub gives the pipeline a signed token: "I am the main branch of Gautamhub1/aws-uptime-monitor."
   2. AWS trusts GitHub's tokens and returns **temporary credentials** that last 1 hour.

   New AWS accounts on the **Free plan block** creating the "identity provider" OIDC needs. The project supports OIDC anyway: set `use_oidc = true` in the bootstrap on an account that allows it.

**In an interview this is a strong point.** You can explain both methods, why you chose one, and the trade-offs.

### SSRF (Server-Side Request Forgery)
`/api/check?url=...` makes our server visit a URL. An attacker could ask it to visit *internal* addresses (like `169.254.169.254` or `10.x.x.x`). `checker.py` blocks any URL that resolves to a non-public IP and doesn't follow redirects, which could otherwise point to an internal address.

---

## Part 3: Every file, explained

| File | What it does |
|---|---|
| `app/checker.py` | `validate_url()` blocks bad and private URLs. `check_url()` does one HTTP request and returns `up`, `status_code`, `latency_ms`. No AWS code, so it's easy to test. |
| `app/handler.py` | The Lambda entry point `lambda_handler()`. If the event comes from EventBridge (`source == "aws.events"`), it runs the checks, saves them to DynamoDB and publishes metrics. Otherwise it's an HTTP request: it routes `/`, `/health`, `/api/status`, `/api/check`. |
| `app/static/dashboard.html` | The web page. Its JavaScript calls `/api/status` every 60 seconds and draws the cards and bars. It uses `textContent`, never `innerHTML`, so data can't inject code. |
| `Dockerfile` | Starts from `public.ecr.aws/lambda/python:3.12`, copies the code, and sets the handler. |
| `tests/` | `pytest` tests. **moto** fakes AWS (DynamoDB, CloudWatch) so the tests run without an AWS account. |
| `terraform/bootstrap/` | The S3 state bucket, the ECR repository, and the GitHub deploy user (or, with `use_oidc = true`, the OIDC provider + role), all with a least-privilege policy (only resources named `uptime-monitor*`). |
| `terraform/app/main.tf` | DynamoDB table, Lambda + its IAM role, EventBridge rule, API Gateway, SNS topic + email, 2 alarms, CloudWatch dashboard. |
| `terraform/app/variables.tf` | Settings you can change: region, monitored URLs, email, check interval. |
| `.github/workflows/pipeline.yml` | Job `test` (always): ruff → pytest → Docker build → container test → terraform validate. Job `deploy` (main only): OIDC login → push image to ECR → terraform apply → smoke test. |

**Exercise:** open each file and try to explain each block in your own words. If something is unclear, ask Claude about that exact block.

---

## Part 4: Deploy it, step by step

### Step 1: Set up your AWS account safely
1. Create an account at <https://aws.amazon.com> (a card is required; we stay in the free tier).
2. **Turn on MFA** for the root user: top-right menu → *Security credentials* → *Assign MFA device*.
3. **Create a budget alert** so you never get a surprise bill: search **Budgets** → *Create budget* → *Use a template* → **Zero spend budget** → enter your email.
4. Find your **home region**: <https://settings.aws.com> → **Projects** → your project → **Additional info → Region**. This project is set to **Europe (Stockholm) eu-north-1**. If yours is different, change `aws_region` in `terraform/bootstrap/variables.tf` and `terraform/app/variables.tf`.
5. In the top-right region menu of the console, select that region.

### Step 2: Create the GitHub repository
1. On GitHub: **New repository** → name it exactly **`aws-uptime-monitor`** → **Public** → don't add a README → **Create**.


### Step 3: Run the one-time bootstrap in AWS CloudShell
CloudShell is a terminal in your browser, already logged in to your AWS account.

1. In the AWS console, click the **CloudShell** icon (`>_`, top bar).
2. **Actions → Upload file** → upload `aws-uptime-monitor.zip`.
3. Run:
   ```bash
   unzip aws-uptime-monitor.zip && cd aws-uptime-monitor

   # Install Terraform into your home folder (CloudShell doesn't include it)
   mkdir -p ~/bin && ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
   curl -sLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/1.10.5/terraform_1.10.5_linux_${ARCH}.zip"
   unzip -o /tmp/tf.zip -d ~/bin && export PATH="$HOME/bin:$PATH"
   echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
   terraform -version     # a "newer version available" message is only a warning

   # Create the state bucket, ECR repository and GitHub deploy user
   cd terraform/bootstrap
   terraform init
   terraform apply        # review the plan, then type: yes
   ```
4. At the end, Terraform prints the **outputs**. Copy `AWS_REGION`, `TF_STATE_BUCKET` and `AWS_ACCESS_KEY_ID`.
5. The secret key is hidden on purpose. Show it with:
   ```bash
   terraform output -raw AWS_SECRET_ACCESS_KEY; echo
   ```
   Copy it **only** into GitHub Secrets (next step). Never paste it in a chat or an email, and never put it in the code.

> **Error with "explicit deny in a service control policy"?** Your account has restrictions from the AWS Free plan. Check that `aws_region` matches your home region (Step 1).
>
> The file `terraform.tfstate` in this folder is the bootstrap's memory. CloudShell keeps your home folder, but download a backup copy anyway (**Actions → Download file**).

### Step 4: Add the secrets and variables in GitHub
In your repository: **Settings → Secrets and variables → Actions**.

**Secrets tab → New repository secret** (encrypted; GitHub never shows them again):

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | from the bootstrap output |
| `AWS_SECRET_ACCESS_KEY` | from `terraform output -raw AWS_SECRET_ACCESS_KEY` |

**Variables tab → New repository variable:**

| Name | Value |
|---|---|
| `AWS_REGION` | `eu-north-1` |
| `TF_STATE_BUCKET` | from the bootstrap output |
| `ALARM_EMAIL` | *(optional)* your email for alerts |
| `TARGET_URLS` | *(optional)* e.g. `https://www.nokia.com,https://github.com` |

### Step 5: Push the code (this triggers the deploy)
On your laptop (with [Git](https://git-scm.com/downloads) installed), unzip the project and run:
```bash
cd aws-uptime-monitor
git init
git add .
git commit -m "Initial commit: serverless uptime monitor"
git branch -M main
git remote add origin https://github.com/Gautamhub1/aws-uptime-monitor.git
git push -u origin main
```
(If Git asks for a password, use a GitHub **personal access token**, or install **GitHub Desktop**, which handles login for you.)

Then open the **Actions** tab on GitHub and watch the pipeline. The first run takes about 3–5 minutes. When it's green, open the run's **Summary**: it shows your **dashboard URL**.

### Step 6: Check that everything works
1. **Open the dashboard URL.** At first it says "Waiting for the first scheduled check". Wait up to 5 minutes, then refresh.
2. Open `<url>/health` to see the deployed version (the Git commit SHA).
3. Try the **"Check any website now"** box.
4. **Email:** if you set `ALARM_EMAIL`, AWS sends a *subscription confirmation* email. Click **Confirm**. About 10 minutes later you'll get an **ALARM** email, because `httpbin.org/status/503` is a site that **fails on purpose** to show the alerting works. You can remove it from `TARGET_URLS` later.
5. In the AWS console, look at:
   - **CloudWatch → Dashboards → uptime-monitor:** graphs
   - **CloudWatch → Alarms:** `uptime-monitor-site-down`
   - **Lambda → uptime-monitor → Monitor → View CloudWatch logs:** the logs
   - **DynamoDB → Tables → uptime-monitor-checks → Explore items:** the stored checks
   - **ECR → uptime-monitor:** one image per deployment

### Step 7: Show the CI/CD workflow (great for interviews)
```bash
git checkout -b improve-dashboard-title
# edit app/static/dashboard.html, e.g. change <h1>Uptime Monitor</h1>
git add . && git commit -m "Improve dashboard title"
git push -u origin improve-dashboard-title
```
On GitHub, open a **pull request** and watch the tests run (no deploy). **Merge** it, watch the deploy run, then refresh the dashboard. The title and the version at the bottom have changed. Do 2–3 small PRs like this so your repo shows a real Git workflow.

**Then take screenshots** of the live dashboard, the CloudWatch dashboard, the alarm email and a green pipeline run. Replace `docs/images/dashboard-preview.png` and put your live URL at the top of the README.

### Step 8: Delete everything (when you want)
In CloudShell, from the project folder:
```bash
cd terraform/app
terraform init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="region=eu-north-1"
terraform destroy -var="image_uri=unused"
cd ../bootstrap && terraform destroy
```
Since it costs about €0, you can also just leave it running while you job-hunt.

---

## Part 5: Explaining it in an interview

### The 60-second pitch (practise it out loud, in your own words)
> "I built a serverless uptime monitor on AWS. An EventBridge schedule triggers a Python Lambda function every five minutes. It checks a list of websites, stores the results in DynamoDB with a 7-day TTL, and publishes custom CloudWatch metrics. A CloudWatch alarm sends an email through SNS when a site fails twice in a row, and API Gateway serves a live dashboard and an API from the same function.
>
> All infrastructure is in Terraform, the function is packaged as a Docker image in ECR, and a GitHub Actions pipeline tests every pull request and deploys main automatically. The pipeline's AWS credentials have least-privilege permissions limited to this project, and the whole thing runs inside the free tier."

### Likely questions and answers

**Why serverless and not EC2?**
The work is small and runs every 5 minutes. With EC2 I'd pay 24/7 for a server that's idle most of the time and I'd have to patch it. Lambda costs almost nothing here and scales automatically. If the job ran constantly, or took longer than Lambda's 15-minute limit, I'd consider ECS or EC2.

**Why package Lambda as a Docker image?**
I can test the exact same image locally and in CI with the Lambda runtime emulator before deploying it. It also allows bigger dependencies (up to 10 GB) than a zip file (250 MB).

**How does the pipeline get access to AWS?**
Through a dedicated IAM user whose access key is stored encrypted in GitHub Secrets. Its policy only allows managing resources named `uptime-monitor*`. The better practice is OIDC, where GitHub gets temporary 1-hour credentials and no keys are stored. My project supports it with one setting, but my AWS Free-plan account blocks creating identity providers, so I used a least-privilege access key and would rotate it regularly. On a company account I'd switch to OIDC.

**What does least privilege mean in your project?**
The Lambda role can only write logs to its own log group, read/write its own DynamoDB table and publish metrics to one namespace. The deploy user can only manage resources whose names start with `uptime-monitor`.

**How did you design the DynamoDB table?**
The partition key is the URL and the sort key is the check timestamp. "The last 24 hours for one site" becomes a single efficient query instead of a scan. TTL deletes old items automatically.

**Why alarm on 2 consecutive failures?**
To avoid false alarms from a single network blip. It's a trade-off between alerting quickly and alerting correctly.

**What's Terraform state, and where is yours?**
It's Terraform's record of what it created. Mine is in an encrypted, versioned S3 bucket with state locking, so the pipeline and I never overwrite each other's changes.

**What security risk does `/api/check` have?**
SSRF: someone could make my server request internal addresses. I resolve the hostname, reject private, loopback and link-local IPs, and don't follow redirects. API Gateway throttling limits abuse.

**What happens if a deploy breaks the app?**
The smoke test calls `/health` and checks the new version. If it fails, the pipeline goes red. To roll back, I revert the commit, and the pipeline redeploys the previous version. Images are tagged by commit SHA, so every version is traceable.

**What would you improve next?**
Manage the monitored sites through the API instead of a variable, add Slack alerts, show a Terraform plan on pull requests, add a custom domain with Route 53 and ACM, and add a permissions boundary on the deploy role.

**What was hard?**
Answer honestly from **your own** experience after deploying it, e.g. understanding OIDC, the IAM permissions, or the bootstrap step.

### For your CV and LinkedIn
> **AWS Serverless Uptime Monitor**: Python, AWS Lambda (Docker/ECR), API Gateway, DynamoDB, EventBridge, CloudWatch, SNS, Terraform, GitHub Actions. Built and deployed a monitoring service with automated CI/CD, least-privilege IAM, alerting and a live dashboard. `github.com/Gautamhub1/aws-uptime-monitor`

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Pipeline: `Credentials could not be loaded` | The secrets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are missing or misspelled (Settings → Secrets and variables → Actions → **Secrets** tab). |
| `explicit deny in a service control policy` | AWS Free-plan restriction. Make sure everything uses your home region (`AWS_REGION` variable and `aws_region` in both `variables.tf` files). |
| Pipeline: `AccessDenied` during Terraform apply | Read the error to see which action failed, and add that action to the deploy role policy in `terraform/bootstrap/main.tf`. Then run `terraform apply` again in CloudShell. |
| Terraform: `Error acquiring the state lock` | A previous run was cancelled. Wait, or run `terraform force-unlock <ID>` with the ID from the error. |
| Dashboard shows "Waiting for the first scheduled check" | Normal for the first 5 minutes. |
| No alarm email | Confirm the SNS subscription email first (check spam). |
| `docker build` fails locally on Apple Silicon Mac | Keep `--platform linux/amd64` in the build command, as the pipeline does. |
