"""
Spark History Server Demo Job for EMR on EKS
============================================

Purpose: 
    Demonstrate various Spark operations and create rich visualizations 
    in Spark History Server when running on Amazon EMR on EKS.

Features Demonstrated:
1. Complex DAG Creation
2. Various Transformation Types
3. Multiple Shuffle Operations
4. Window Functions
5. SQL Operations
6. Memory Usage Patterns
7. S3 I/O Operations

History Server Visualization Points:
- Multiple stage dependencies
- Shuffle patterns
- Memory usage
- Task distribution
- SQL query plans
- Resource utilization

Usage:
    Deployed via Spark Operator using SparkApplication CR
    All configurations managed via manifest file

Author: Suvojit Dasgupta
Date: May 01, 2025
Version: 1.0
"""

from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, rand, sin, pow, count, sum, avg, 
    percentile_approx, broadcast, row_number, 
    rank, dense_rank, stddev, max
)
from pyspark.sql.window import Window
from pyspark.sql.types import StructType, StructField, LongType, DoubleType
import argparse

def create_spark_session():
    """Create basic Spark session"""
    return SparkSession.builder \
        .getOrCreate()

def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description='Spark History Server Demo Job')
    parser.add_argument('--input-path', required=True, help='Input path in S3')
    parser.add_argument('--output-path', required=True, help='Output path in S3')
    return parser.parse_args()


def run_complex_spark_job(input_path, output_path):
    """Execute complex Spark operations for History Server demonstration"""

    print(f"Input path: {input_path}")
    print(f"Output path: {output_path}")
    
    if not input_path or not output_path:
        raise ValueError("INPUT_PATH and OUTPUT_PATH must be set in the environment variables.")

    spark = create_spark_session()
    print(f"Starting Spark History Demo Job ...")

    # Generate initial dataset
    print("Creating initial dataset...")
    df = spark.range(0, 10000000)

    # Add some columns to make the initial dataset more interesting
    df = df.withColumn("value", rand()) \
           .withColumn("group", col("id") % 1000)
    
    # Write to S3
    print(f"Writing initial dataset to S3: {input_path}/raw_data")
    df.write.mode("overwrite").parquet(f"{input_path}/raw_data")
    
    # Force execution of the write operation
    spark.sparkContext.setJobDescription("Writing initial dataset")
    initial_count = df.count()
    print(f"Initial dataset count: {initial_count}")

    # Define the schema
    schema = StructType([
        StructField("id", LongType(), True),
        StructField("value", DoubleType(), True),
        StructField("group", LongType(), True)
    ])

    # Read from S3 with explicit schema
    print(f"Reading dataset from S3: {input_path}/raw_data")
    df = spark.read.schema(schema).parquet(f"{input_path}/raw_data")

    # Verify the data was read successfully
    read_count = df.count()
    print(f"Read {read_count} records from S3")
    
    if read_count == 0:
        raise ValueError("No data was read from the input path. Please check the S3 location.")

    # Cache data
    print("Caching dataset...")
    df.persist()
    df.count()

    # Complex transformations
    print("Performing complex transformations...")
    df1 = df.withColumn("random", rand()) \
           .withColumn("group", col("id") % 1000) \
           .withColumn("complex_calc", 
                      pow(col("random"), 2) + sin(col("id"))) \
           .repartition(200)

    # Aggregations
    print("Performing aggregations...")
    df2 = df1.groupBy("group") \
            .agg(
                count("*").alias("count"),
                sum("complex_calc").alias("sum"),
                avg("random").alias("avg"),
                percentile_approx("random", 0.5).alias("median")
            )

    # Join operations
    print("Performing joins...")
    df3 = df1.join(broadcast(df2), "group")

    # Window functions
    print("Calculating window functions...")
    window_spec = Window.partitionBy("group").orderBy("random")
    
    df4 = df3.withColumn("row_number", row_number().over(window_spec)) \
             .withColumn("rank", rank().over(window_spec)) \
             .withColumn("dense_rank", dense_rank().over(window_spec))

    print(f"Total processed records: {df4.count()}")

    # SQL operations
    print("Performing SQL operations...")
    df4.createOrReplaceTempView("complex_data")
    
    sql_result = spark.sql("""
        SELECT 
            group,
            avg(complex_calc) as avg_calc,
            max(random) as max_random,
            min(random) as min_random,
            approx_count_distinct(id) as distinct_ids
        FROM complex_data
        GROUP BY group
        HAVING count(*) > 100
        ORDER BY group
    """)
    
    # Write results
    print(f"Writing SQL results to: {output_path}/sql_results")
    sql_result.write.mode("overwrite").parquet(f"{output_path}/sql_results")

    # Final aggregations
    print("Performing final aggregations...")
    final_result = df4.repartition(100).groupBy("group") \
                     .agg(
                         count("*").alias("count"),
                         sum(col("complex_calc")).alias("sum_calc"),
                         avg(col("random")).alias("avg_random"),
                         max(col("row_number")).alias("max_row_num"),
                         stddev(col("complex_calc")).alias("std_dev")
                     )
    
    print(f"Writing final results to: {output_path}/final_results")
    final_result.write.mode("overwrite").parquet(f"{output_path}/final_results")

    print("\nSample of final results:")
    final_result.orderBy("group").show(5)

    final_count = final_result.count()
    print(f"Final result count: {final_count}")

    print(f"\nJob completed successfully!")
    print(f"Results available at: {output_path}")
    
    spark.stop()

if __name__ == "__main__":
    args = parse_arguments()
    run_complex_spark_job(args.input_path, args.output_path)
