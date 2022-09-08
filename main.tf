data "aws_caller_identity" "current" {
  count = var.enable_data_format_conversion || var.s3_backup_enable_log ? 1 : 0
}

data "aws_region" "current" {
  count = var.enable_data_format_conversion || var.enable_s3_backup ? 1 : 0
}

locals {
  firehose_role_arn = var.create_role ? aws_iam_role.firehose[0].arn : var.firehose_role

  # Data Transformation
  enable_processing     = var.transform_lambda_arn != null || var.enable_dynamic_partitioning
  enable_transformation = var.transform_lambda_arn != null
  lambda_processor = local.enable_processing && local.enable_transformation ? {
    type = "Lambda"
    parameters = [
      {
        name  = "LambdaArn"
        value = var.transform_lambda_arn
      },
      {
        name  = "BufferSizeInMBs"
        value = var.transform_lambda_buffer_size
      },
      {
        name  = "BufferIntervalInSeconds"
        value = var.transform_lambda_buffer_interval
      },
      {
        name  = "NumberOfRetries"
        value = var.transform_lambda_number_retries
      },
    ]
  } : null
  metadata_extractor_processor = local.enable_processing && var.dynamic_partition_metadata_extractor_query != null ? {
    type = "MetadataExtraction"
    parameters = [
      {
        name  = "JsonParsingEngine"
        value = "JQ-1.6"
      },
      {
        name  = "MetadataExtractionQuery"
        value = var.dynamic_partition_metadata_extractor_query
      },
    ]
  } : null
  append_delimiter_processor = local.enable_processing && var.dynamic_partition_append_delimiter_to_record ? {
    type       = "AppendDelimiterToRecord"
    parameters = []
  } : null
  record_deaggregation_processor_json = {
    type = "RecordDeAggregation"
    parameters = [
      {
        name  = "SubRecordType"
        value = var.dynamic_partition_record_deaggregation_type
      },
    ]
  }
  record_deaggregation_processor_delimiter = {
    type = "RecordDeAggregation"
    parameters = [
      {
        name  = "SubRecordType"
        value = var.dynamic_partition_record_deaggregation_type
      },
      {
        name  = "Delimiter"
        value = var.dynamic_partition_record_deaggregation_delimiter
      },
    ]
  }
  record_deaggregation_processor = (local.enable_processing && var.dynamic_partition_enable_record_deaggregation ?
    (var.dynamic_partition_record_deaggregation_type == "JSON" ? local.record_deaggregation_processor_json : local.record_deaggregation_processor_delimiter)
  : null)
  processors = [for each in [
    local.lambda_processor,
    local.metadata_extractor_processor,
    local.append_delimiter_processor,
    local.record_deaggregation_processor
  ] : each if local.enable_processing && each != null]

  # Data Format conversion
  data_format_conversion_glue_catalog_id = (var.enable_data_format_conversion ?
    (var.data_format_conversion_glue_catalog_id != null ? var.data_format_conversion_glue_catalog_id : data.aws_caller_identity.current[0].account_id)
  : null)

  data_format_conversion_glue_region = (var.enable_data_format_conversion ?
    (var.data_format_conversion_glue_region != null ? var.data_format_conversion_glue_region : data.aws_region.current[0].name)
  : null)

  data_format_conversion_glue_role = (var.enable_data_format_conversion ? (
    var.data_format_conversion_glue_use_existing_role ? local.firehose_role_arn : var.data_format_conversion_glue_role_arn
  ) : null)

  # S3 Backup
  s3_backup_mode = var.enable_s3_backup ? "Enabled" : "Disabled"
  s3_backup_mode_role_arn = (var.enable_s3_backup ? (
    var.s3_backup_use_existing_role ? local.firehose_role_arn : var.s3_backup_role_arn
  ) : null)
  s3_backup_cw_log_group_name  = var.enable_s3_backup && var.s3_backup_log_group_name != null ? var.s3_backup_log_group_name : "/aws/kinesisfirehose/${var.name}"
  s3_backup_cw_log_stream_name = var.enable_s3_backup && var.s3_backup_log_group_name != null ? var.s3_backup_log_stream_name : "BackupDelivery"
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = var.name
  destination = var.destination

  server_side_encryption {
    enabled = var.sse_enabled
    key_arn = var.sse_key_arn
    key_type = var.ss3_key_type
  }

  extended_s3_configuration {
    role_arn            = local.firehose_role_arn
    bucket_arn          = var.s3_bucket_arn
    prefix              = var.s3_prefix
    error_output_prefix = var.s3_error_output_prefix
    buffer_size         = var.buffer_size
    buffer_interval     = var.buffer_interval
    s3_backup_mode      = local.s3_backup_mode

    dynamic_partitioning_configuration {
      enabled        = var.enable_dynamic_partitioning
      retry_duration = var.dynamic_partitioning_retry_duration
    }

    processing_configuration {
      enabled = local.enable_processing
      dynamic "processors" {
        for_each = local.processors
        content {
          type = processors.value["type"]
          dynamic "parameters" {
            for_each = processors.value["parameters"]
            content {
              parameter_name  = parameters.value["name"]
              parameter_value = parameters.value["value"]
            }
          }
        }
      }
    }

    dynamic "data_format_conversion_configuration" {
      for_each = var.enable_data_format_conversion ? [1] : []
      content {
        input_format_configuration {
          deserializer {
            dynamic "open_x_json_ser_de" {
              for_each = var.data_format_conversion_deserializer == "OpenX" ? [1] : []
              content {
                case_insensitive                         = var.data_format_conversion_openX_case_insensitive
                convert_dots_in_json_keys_to_underscores = var.data_format_conversion_openX_convert_dots_to_underscores
                column_to_json_key_mappings              = var.data_format_conversion_openX_column_to_json_key_mappings
              }
            }
            dynamic "hive_json_ser_de" {
              for_each = var.data_format_conversion_deserializer == "HIVE" ? [1] : []
              content {
                timestamp_formats = var.data_format_conversion_hive_timestamps
              }
            }
          }
        }

        output_format_configuration {
          serializer {
            dynamic "parquet_ser_de" {
              for_each = var.data_format_conversion_serializer == "PARQUET" ? [1] : []
              content {
                block_size_bytes              = var.data_format_conversion_block_size
                compression                   = var.data_format_conversion_parquet_compression
                enable_dictionary_compression = var.data_format_conversion_parquet_dict_compression
                max_padding_bytes             = var.data_format_conversion_parquet_max_padding
                page_size_bytes               = var.data_format_conversion_parquet_page_size
                writer_version                = var.data_format_conversion_parquet_writer_version
              }
            }
            dynamic "orc_ser_de" {
              for_each = var.data_format_conversion_serializer == "ORC" ? [1] : []
              content {
                block_size_bytes                        = var.data_format_conversion_block_size
                compression                             = var.data_format_conversion_orc_compression
                format_version                          = var.data_format_conversion_orc_format_version
                enable_padding                          = var.data_format_conversion_orc_enable_padding
                padding_tolerance                       = var.data_format_conversion_orc_padding_tolerance
                dictionary_key_threshold                = var.data_format_conversion_orc_dict_key_threshold
                bloom_filter_columns                    = var.data_format_conversion_orc_bloom_filter_columns
                bloom_filter_false_positive_probability = var.data_format_conversion_orc_bloom_filter_false_positive_probability
                row_index_stride                        = var.data_format_conversion_orc_row_index_stripe
                stripe_size_bytes                       = var.data_format_conversion_orc_stripe_size
              }
            }
          }
        }

        schema_configuration {
          database_name = var.data_format_conversion_glue_database
          role_arn      = local.data_format_conversion_glue_role
          table_name    = var.data_format_conversion_glue_table_name
          catalog_id    = local.data_format_conversion_glue_catalog_id
          region        = local.data_format_conversion_glue_region
          version_id    = var.data_format_conversion_glue_version_id
        }
      }
    }

    dynamic "s3_backup_configuration" {
      for_each = var.enable_s3_backup ? [1] : []
      content {
        bucket_arn          = var.s3_backup_bucket_arn
        role_arn            = local.s3_backup_mode_role_arn
        prefix              = var.s3_backup_prefix
        buffer_size         = var.s3_backup_buffer_size
        buffer_interval     = var.s3_backup_buffer_interval
        compression_format  = var.s3_backup_compression
        error_output_prefix = var.s3_backup_error_output_prefix
        kms_key_arn         = var.s3_backup_kms_key_arn
        cloudwatch_logging_options {
          enabled         = var.s3_backup_enable_log
          log_group_name  = local.s3_backup_cw_log_group_name
          log_stream_name = local.s3_backup_cw_log_stream_name
        }
      }
    }

  }

  tags = var.tags

}

##################
# Cloudwatch
##################
resource "aws_cloudwatch_log_group" "s3_backup" {
  count = var.enable_s3_backup && var.s3_backup_create_cw_log_group ? 1 : 0

  name              = local.s3_backup_cw_log_group_name
  retention_in_days = var.s3_backup_log_retention_in_days
  #  kms_key_id        = var.s3_backup_kms_key_arn

  tags = merge(var.tags, var.s3_backup_cw_tags)
}

resource "aws_cloudwatch_log_stream" "s3_backup" {
  count = var.enable_s3_backup && var.s3_backup_create_cw_log_group ? 1 : 0

  name           = local.s3_backup_cw_log_stream_name
  log_group_name = aws_cloudwatch_log_group.s3_backup[0].name
}
