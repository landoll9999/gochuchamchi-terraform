# Container image build/signing separation

## Trust boundaries

- The build job assumes `github_actions_ecr_role_arn` and can publish only a
  candidate image in the intended workflow.
- The signing job assumes `github_actions_image_signer_role_arn` only after
  approval in the protected GitHub Environment named `production-signing`.
- Cosign asks the asymmetric AWS KMS key to sign the image digest. The private
  key never leaves KMS.
- The signing job promotes the verified digest to `signed-<40-character SHA>`.
- ArgoCD Image Updater ignores `candidate-*` and follows only `signed-*` tags.
- Kyverno verifies the Cosign signature before admitting the application Pod.

The ECR repository uses `IMMUTABLE_WITH_EXCLUSION`. Candidate and signed image
tags cannot be moved to another digest, while Cosign reference artifact tags
(`sha256-*.sig`, `sha256-*.att`, and `sha256-*.sbom`) remain mutable so that
signatures, attestations, and SBOMs can be added or rotated. Candidate tags also
include the GitHub run ID and attempt so that rerunning a workflow never collides
with an immutable tag from an earlier attempt.

## 1. Apply the Terraform in Audit mode

Keep the default during the first rollout:

```hcl
image_signature_validation_action = "Audit"
```

Run Terraform and capture the workflow values:

```powershell
terraform apply
terraform output -raw github_actions_ecr_role_arn
terraform output -raw github_actions_image_signer_role_arn
terraform output -raw image_signing_kms_key_arn
terraform output -raw ecr_repository_url
```

## 2. Protect the signing Environment in gochuchamchi-spring

In GitHub, open `Settings -> Environments` and create:

```text
production-signing
```

Configure:

- Required reviewers: at least one teammate who is not the code author.
- Deployment branches and tags: selected branches, `main` only.
- Prevent administrators from bypassing the approval when the GitHub plan
  supports it.

Add the following repository variables:

| Variable | Terraform output |
|---|---|
| `AWS_ECR_BUILD_ROLE_ARN` | `github_actions_ecr_role_arn` |
| `AWS_IMAGE_SIGNER_ROLE_ARN` | `github_actions_image_signer_role_arn` |
| `IMAGE_SIGNING_KMS_KEY_ARN` | `image_signing_kms_key_arn` |
| `ECR_REPOSITORY_URL` | `ecr_repository_url` |

These values are identifiers, not secrets.

## 3. Separate the build and signing jobs

Add this structure to the `gochuchamchi-spring` workflow. Before production,
replace action version tags with reviewed full commit SHAs.

```yaml
name: Build and sign release image

on:
  push:
    branches: [main]

permissions:
  contents: read

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY_URL: ${{ vars.ECR_REPOSITORY_URL }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    outputs:
      digest: ${{ steps.build.outputs.digest }}

    steps:
      - uses: actions/checkout@v5

      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ vars.AWS_ECR_BUILD_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: aws-actions/amazon-ecr-login@v2

      - uses: docker/setup-buildx-action@v3

      - name: Build and push candidate
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.ECR_REPOSITORY_URL }}:candidate-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}

  sign:
    needs: build
    runs-on: ubuntu-latest
    environment: production-signing
    permissions:
      contents: read
      id-token: write

    steps:
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ vars.AWS_IMAGE_SIGNER_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: aws-actions/amazon-ecr-login@v2

      - uses: sigstore/cosign-installer@v3

      - name: Sign digest with the KMS key
        env:
          IMAGE_DIGEST: ${{ needs.build.outputs.digest }}
          KMS_KEY_ARN: ${{ vars.IMAGE_SIGNING_KMS_KEY_ARN }}
        run: |
          cosign sign --yes \
            --key "awskms:///${KMS_KEY_ARN}" \
            "${ECR_REPOSITORY_URL}@${IMAGE_DIGEST}"

      - name: Promote the signed digest
        env:
          IMAGE_DIGEST: ${{ needs.build.outputs.digest }}
        run: |
          REPOSITORY_NAME="${ECR_REPOSITORY_URL##*/}"
          MANIFEST="$(aws ecr batch-get-image \
            --repository-name "${REPOSITORY_NAME}" \
            --image-ids imageDigest="${IMAGE_DIGEST}" \
            --query 'images[0].imageManifest' \
            --output text)"

          aws ecr put-image \
            --repository-name "${REPOSITORY_NAME}" \
            --image-tag "signed-${GITHUB_SHA}" \
            --image-manifest "${MANIFEST}"

      - name: Verify the published signature
        env:
          IMAGE_DIGEST: ${{ needs.build.outputs.digest }}
          KMS_KEY_ARN: ${{ vars.IMAGE_SIGNING_KMS_KEY_ARN }}
        run: |
          cosign verify \
            --key "awskms:///${KMS_KEY_ARN}" \
            "${ECR_REPOSITORY_URL}@${IMAGE_DIGEST}"
```

## 4. Verify Audit results

After a signed release is deployed:

```powershell
kubectl get namespacedimagevalidatingpolicies.policies.kyverno.io -A
kubectl get policyreport -n gochuchamchi
kubectl describe policyreport -n gochuchamchi
```

Test that an unsigned candidate is reported but does not yet interrupt the
running application.

## 5. Enable blocking only after the signed pipeline works

Set:

```powershell
$env:TF_VAR_image_signature_validation_action = "Deny"
terraform apply
```

In `Deny` mode, Kyverno also mutates matching tags to immutable digests and
fails closed when signature verification cannot succeed. Unsigned application
images are rejected before their Pods start.

## Rollback

If signature verification blocks an emergency recovery, return to Audit:

```powershell
$env:TF_VAR_image_signature_validation_action = "Audit"
terraform apply
```

Do not delete the KMS key to bypass verification. KMS key deletion has a
30-day waiting period and would make every existing signature unverifiable.
