# EMR 7.2.0 comes with Apache Spark 3.5.1
# https://docs.aws.amazon.com/emr/latest/ReleaseGuide/emr-720-release.html
FROM  public.ecr.aws/emr-on-eks/spark/emr-7.2.0:20241010@sha256:aa3502c641058ae81cc94a36a052db90673744cd90f37838238eee64571fbd71

# Define build-time arguments
ARG SCALA_VERSION=2.12
ARG DATAFLINT_VERSION=0.3.2

# https://repo1.maven.org/maven2/io/dataflint/spark_${SCALA_VERSION}/${DATAFLINT_VERSION}/spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar.sha1
ARG DATAFLINT_SHA1="5b812af683705fa178cf56c5d97d8cd6d573c7b7"

# Switch to root to install additional packages
USER root

# Set shell to bash with pipefail option
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DataFlint - Download checksum , download the Jar and Verify Checksum
RUN curl -L "https://repo1.maven.org/maven2/io/dataflint/spark_${SCALA_VERSION}/${DATAFLINT_VERSION}/spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar" -o "/usr/lib/spark/jars/dataflint-spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar" && \
    echo "${DATAFLINT_SHA1}" "/usr/lib/spark/jars/dataflint-spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar" | sha1sum -c -

# Add HEALTHCHECK instruction to verify Spark processes
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD ["CMD-SHELL", "pgrep java && ls /usr/lib/spark/jars/dataflint-spark*.jar || exit 1"]

# Switch back to hadoop user
USER hadoop:hadoop

