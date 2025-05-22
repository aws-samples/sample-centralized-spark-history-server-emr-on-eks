# Use official Apache Spark base image with version 3.5.0
FROM apache/spark:3.5.0@sha256:0ed5154e6b32ac3af1272d4d65e9f65b13afcfe80b41ad10bd059bcd6317863c

# Define build-time arguments
ARG SPARKUSERNAME="spark"
ARG HADOOP_AWS_VERSION=3.3.4
ARG AWS_SDK_VERSION=1.12.780
ARG SCALA_VERSION=2.12
ARG DATAFLINT_VERSION=0.3.2

# https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar.sha1
ARG HADOOP_AWS_SHA1="a65839fbf1869f81a1632e09f415e586922e4f80"
# https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VERSION}/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar.sha1
ARG AWS_SDK_SHA1="308a3af95a47e0c4e1f8bd98a37657d4661ae45e"
# https://repo1.maven.org/maven2/io/dataflint/spark_${SCALA_VERSION}/${DATAFLINT_VERSION}/spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar.sha1
ARG DATAFLINT_SHA1="5b812af683705fa178cf56c5d97d8cd6d573c7b7"

# Set environment variables for Spark configuration
ENV SPARK_HOME=/opt/spark \
    SPARK_CONF_DIR=/opt/spark/conf

# Set working directory to Spark installation directory
WORKDIR /opt/spark

# Switch to root to install additional packages
USER root

# Set shell to bash with pipefail option
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install AWS CLI and create necessary directories and set proper ownership
RUN pip3 install --upgrade --no-cache-dir awscli && \
    mkdir -p /home/spark && \
    chown -R ${SPARKUSERNAME}:${SPARKUSERNAME} /home/spark /opt/spark

# hadoop-aws - Download checksum , download the Jar and Verify Checksum
RUN curl -L "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" -o "${SPARK_HOME}/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar" && \
    echo "${HADOOP_AWS_SHA1}" "${SPARK_HOME}/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar" | sha1sum -c -

# aws-java-sdk-bundle - Download checksum , download the Jar and Verify Checksum
RUN curl -L "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VERSION}/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar" -o "${SPARK_HOME}/jars/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar" && \
    echo "${AWS_SDK_SHA1}" "${SPARK_HOME}/jars/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar" | sha1sum -c -

# DataFlint - Download checksum , download the Jar and Verify Checksum
RUN curl -L "https://repo1.maven.org/maven2/io/dataflint/spark_${SCALA_VERSION}/${DATAFLINT_VERSION}/spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar" -o "${SPARK_HOME}/jars/dataflint-spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar" && \
    echo "${DATAFLINT_SHA1}" "${SPARK_HOME}/jars/dataflint-spark_${SCALA_VERSION}-${DATAFLINT_VERSION}.jar" | sha1sum -c -

RUN mkdir -p /opt/spark/logs && chown -R 1000:1000 /opt/spark

# Expose the default Spark History Server port
EXPOSE 18080

# Add user and group entries
RUN echo '1000:x:1000:1000:anonymous uid:/opt/spark:/bin/false' >> /etc/passwd && \
    echo 'spark:x:1000:' >> /etc/group

# Switch back to spark user
USER ${SPARKUSERNAME}

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD ["curl", "-f", "http://localhost:18080"]

# Set the entrypoint
ENTRYPOINT ["/bin/bash", "-c", "exec \"$@\""]