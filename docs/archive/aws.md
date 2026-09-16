To give another agent access to your SSM instance, you'd need to provide:

## Essential Information:

1. **Instance ID**: `i-0268c831a241111fe`
2. **AWS Region**: `eu-west-1`
3. **AWS Profile Name**: `godson` (locally configured)

## Command Pattern:
```bash
CID=$(aws ssm send-command \
  --instance-ids i-0268c831a241111fe \
  --region eu-west-1 \
  --profile godson \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["<YOUR_COMMAND>"]' \
  --query Command.CommandId --output text) \
&& sleep 10 \
&& aws ssm get-command-invocation \
  --command-id "$CID" \
  --instance-id i-0268c831a241111fe \
  --region eu-west-1 \
  --profile godson \
  --query StandardOutputContent --output text
```

## Additional Context (Optional but Helpful):

- **Service Path**: `/opt/gptc` (where the GPTC API runs)
- **Docker Compose**: Service uses `docker compose` commands
- **Service Name**: `api` (in docker compose)
- **Logs Command**: `docker compose logs api --since <time>`

## AWS Profile Setup:
If the agent needs to know how AWS is configured locally:
```bash
# Check current AWS credentials
aws configure list --profile godson

# Credentials are stored in:
# ~/.aws/credentials (access keys)
# ~/.aws/config (region, output format)
```
