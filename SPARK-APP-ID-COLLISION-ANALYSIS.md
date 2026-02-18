# Spark Application ID Collision Analysis

This document analyzes the collision probability of `spark.app.id` values when aggregating Apache Spark logs from multiple EMR on EKS clusters to a central S3 bucket.

## Overview

When using a centralized Spark History Server to visualize logs from multiple EMR on EKS clusters, all clusters write their event logs to the same `spark.eventLog.dir` in S3. The logs are organized by `spark.app.id` as the prefix. If two applications generate the same `spark.app.id`, one could overwrite the other's logs.

This analysis covers two job submission methods:
- **Case 1**: EMR `start-job-run` API
- **Case 2**: Spark Operator on Kubernetes

---

## How spark.app.id is Generated

### Generation Methods by Deployment Type

The `spark.app.id` is generated differently depending on how you submit your Spark job:

1. **EMR on EKS (start-job-run API)** - Case 1:
   - EMR's job orchestration layer generates the application ID
   - Format: `spark-<19 alphanumeric characters>`
   - EMR manages job lifecycle and assigns its own unique identifiers

2. **Spark Operator / spark-submit to Kubernetes** - Case 2:
   - Spark generates the ID locally on the client side before submitting to Kubernetes
   - Generated in `KubernetesConf.scala`
   - Format: `spark-[randomUUID-without-dashes]`
   - Uses Java's `UUID.randomUUID()` producing a 128-bit random UUID

3. **Other Modes (for reference)**:
   - **Local Mode**: `local-<timestamp>` (e.g., `local-1564252213176`)
   - **YARN**: Application ID provided by YARN ResourceManager (e.g., `application_1234567890123_0001`)
   - **Standalone Cluster**: ID provided by Spark Master

---

## Case 1: EMR start-job-run API

### Log Folder Structure

When using the EMR `start-job-run` API, Spark logs are written to S3 using the EMR-generated application ID as the prefix.

**Format**: `spark-<19 alphanumeric characters>`

**Example**: `spark-0000000373cbh7ro61p`

### Character Analysis

The 19-character suffix uses:
- **Digits**: 0-9 (10 characters)
- **Lowercase letters**: a-z (26 characters)
- **Total character set**: 36 characters (base-36 encoding)

### Total Possible IDs

```
Total combinations = 36^19
                   = 36^19
                   ≈ 1.35 × 10^29
```

In bits: `log₂(36^19) ≈ 98.4 bits` of entropy

### Collision Model (Birthday Paradox)

Let:
- `n` = total number of Spark applications writing to the same `spark.eventLog.dir`
- `N` = 36^19 ≈ 1.35 × 10^29

**Collision probability formula**:
```
P(collision) ≈ n² / (2N)
```

### Concrete Example: Large Real-World Environment

**Assumptions**:
- 100 clusters
- 1,000 Spark jobs per cluster per day
- n = 100,000 jobs/day

**Calculation**:
```
P ≈ (10^5)² / (2 × 1.35 × 10^29)
  ≈ 10^10 / (2.7 × 10^29)
  ≈ 3.7 × 10^-20
```

**Interpretation**: One collision every ~10^20 days (approximately 2.7 × 10^17 years)

### Extreme Scale Analysis

Even at 1 million jobs per day across all clusters:
```
P ≈ (10^6)² / (2 × 1.35 × 10^29)
  ≈ 10^12 / (2.7 × 10^29)
  ≈ 3.7 × 10^-18
```

**Interpretation**: One collision every ~10^18 days (approximately 2.7 × 10^15 years)

---

## Case 2: Spark Operator on Kubernetes

### Log Folder Structure

When using Spark Operator (or native `spark-submit` to Kubernetes), the `spark.app.id` is generated locally using Java's `UUID.randomUUID()`.

**Format**: `spark-<32 lowercase hex characters>`

**Example**: `spark-3f9c2a1b8e4d4a3f9b0e6a2c7d4e5f91`

### Source Code Generation

From Apache Spark source (`KubernetesConf.scala`):
```scala
def getKubernetesAppId(): String =
  s"spark-${UUID.randomUUID().toString.replaceAll("-", "")}"
```

This generates a UUID v4 (random) and removes the dashes, resulting in 32 hex characters.

### Character Analysis

- **32 hex characters**: 0-9, a-f (16 characters per position)
- **Total bits**: 32 × 4 = 128 bits
- **Total possible IDs**: 2^128 ≈ 3.4 × 10^38

### Collision Model (Birthday Paradox)

Let:
- `n` = total number of Spark applications
- `N` = 2^128 ≈ 3.4 × 10^38

**Collision probability formula**:
```
P(collision) ≈ n² / (2N)
```

### Concrete Example: Large Real-World Environment

**Assumptions**:
- 100 clusters
- 1,000 Spark jobs per cluster per day
- n = 100,000 jobs/day

**Calculation**:
```
P ≈ (10^5)² / (2 × 2^128)
  ≈ 10^10 / (6.8 × 10^38)
  ≈ 1.47 × 10^-29
```

**Interpretation**: One collision every ~10^29 days (approximately 2.7 × 10^26 years)

### Extreme Scale Analysis

Even at 1 million jobs per day across all clusters:
```
P ≈ (10^6)² / (2 × 2^128)
  ≈ 10^12 / (6.8 × 10^38)
  ≈ 1.47 × 10^-27
```

**Interpretation**: One collision every ~10^27 days (approximately 2.7 × 10^24 years)

---

## Comparison Summary

| Metric | Case 1: EMR start-job-run | Case 2: Spark Operator |
|--------|---------------------------|------------------------|
| **ID Format** | `spark-<19 base-36 chars>` | `spark-<32 hex chars>` |
| **Example** | `spark-0000000373cbh7ro61p` | `spark-3f9c2a1b8e4d4a3f9b0e6a2c7d4e5f91` |
| **Generation Method** | EMR internal ID | `UUID.randomUUID()` |
| **Entropy** | ~98.4 bits | 128 bits |
| **Total Possible IDs** | ~1.35 × 10^29 | ~3.4 × 10^38 |
| **Collision P (100K jobs/day)** | ~3.7 × 10^-20 | ~1.47 × 10^-29 |
| **Time to Collision** | ~10^17 years | ~10^26 years |

---

## Collision Requirements

For a log overwrite collision to occur, both conditions must be met:
1. Same `spark.eventLog.dir` (S3 path)
2. Same `spark.app.id` value

**Note on probability calculations**: In a centralized logging architecture, all clusters write to the same `spark.eventLog.dir` by design. Therefore, condition #1 is always satisfied. The collision probability calculations in this document focus solely on condition #2 - the likelihood of two jobs generating the same `spark.app.id`.

---

## Conclusion

### Case 1 (EMR start-job-run API)
- Uses ~98.4 bits of entropy (base-36 encoding)
- At realistic operational scales (100K jobs/day), collision probability is ~3.7 × 10^-20
- **Mathematically negligible** - one collision expected every ~10^17 years

### Case 2 (Spark Operator)
- Uses 128 bits of entropy (Java UUID v4)
- Generated via `UUID.randomUUID().toString.replaceAll("-", "")`
- At realistic operational scales (100K jobs/day), collision probability is ~1.47 × 10^-29
- **Mathematically negligible** - one collision expected every ~10^26 years

### Final Assessment

Both methods provide collision probabilities that are:
- **Astronomically small** at any realistic scale
- **Effectively zero** for practical purposes

The Spark Operator method (Case 2) provides approximately 10^9 times more ID space than the EMR start-job-run method (Case 1), but both are far beyond any practical collision risk threshold.

**Recommendation**: No additional collision mitigation is required for either job submission method when using centralized Spark History Server logging.

---

## References

- [Apache Spark Source - KubernetesConf](https://github.com/apache/spark/blob/master/resource-managers/kubernetes/core/src/main/scala/org/apache/spark/deploy/k8s/KubernetesConf.scala)