terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    random = {
      source = "hashicorp/random"
    }
    azuread = {
      source = "hashicorp/azuread"
    }
    time = {
      source = "hashicorp/time"
    }
    databricks = {
      source  = "local/providers/databricks"
      version = "1.0.0"
    }
  }
  required_version = ">= 0.13"
}

provider "azurerm" {
  features {}
}

resource "random_string" "name" {
  length  = 4
  special = false
  upper   = false
}

resource "random_password" "sp" {
  length  = 32
  special = true
  upper   = true
  lower   = true
  number  = true
}

locals {
  location      = "eastus2"
  name          = "testdbks${random_string.name.result}"
  spark_version = "6.6.x-scala2.11"
  spark_node    = "Standard_DS3_v2"
}

data "azurerm_client_config" "c" {}

resource "azuread_application" "app" {
  name = "tf-sp-${local.name}"
  required_resource_access {
    resource_app_id = "e406a681-f3d4-42a8-90b6-c2b029497af1"
    resource_access {
      id   = "03e0da56-190b-40ad-a80c-ea378c433f7f"
      type = "Scope"
    }
  }
  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "sp" {
  application_id = azuread_application.app.application_id
}

resource "time_rotating" "sp" {
  rotation_months = 1
}

resource "azuread_service_principal_password" "sp" {
  service_principal_id = azuread_service_principal.sp.id
  value                = random_password.sp.result
  end_date             = time_rotating.sp.rotation_rfc3339
}

resource "azurerm_resource_group" "rg" {
  location = local.location
  name     = "rg${local.name}"
}

resource "azurerm_databricks_workspace" "dbks" {
  location            = local.location
  name                = "dbks${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "standard"
}

resource "azurerm_storage_account" "sa_adls" {
  account_replication_type = "LRS"
  account_tier             = "Standard"
  location                 = local.location
  name                     = "saadls${local.name}"
  resource_group_name      = azurerm_resource_group.rg.name
  is_hns_enabled           = true
}

resource "azurerm_storage_account" "sa_blob" {
  account_replication_type = "LRS"
  account_tier             = "Standard"
  location                 = local.location
  name                     = "sablob${local.name}"
  resource_group_name      = azurerm_resource_group.rg.name
  is_hns_enabled           = false
}

resource "azurerm_role_assignment" "sa_blob_data" {
  principal_id         = azuread_service_principal.sp.object_id
  scope                = azurerm_storage_account.sa_blob.id
  role_definition_name = "Storage Blob Data Owner"
}

resource "azurerm_role_assignment" "sa_adls_data" {
  principal_id         = azuread_service_principal.sp.object_id
  scope                = azurerm_storage_account.sa_adls.id
  role_definition_name = "Storage Blob Data Owner"
}

resource "azurerm_storage_container" "container" {
  name                 = "testing"
  storage_account_name = azurerm_storage_account.sa_blob.name
}

resource "azurerm_storage_data_lake_gen2_filesystem" "fs" {
  name               = "testing"
  storage_account_id = azurerm_storage_account.sa_adls.id
}

provider "databricks" {
  azure_workspace_resource_id = azurerm_databricks_workspace.dbks.id
}

resource "databricks_instance_pool" "pool" {
  instance_pool_name                    = "pool"
  min_idle_instances                    = 0
  idle_instance_autotermination_minutes = 10
  node_type_id                          = local.spark_node
  preloaded_spark_versions              = [local.spark_version]
}

resource "databricks_cluster" "cluster" {
  cluster_name            = "interactive"
  spark_version           = local.spark_version
  instance_pool_id        = databricks_instance_pool.pool.id
  autotermination_minutes = 10
  autoscale {
    min_workers = 1
    max_workers = 2
  }
}

resource "databricks_token" "token" {
  comment = "testing"
}

resource "databricks_secret_scope" "storage" {
  name                     = "storage"
  initial_manage_principal = "users"
}

resource "databricks_secret" "sp_password" {
  key          = "sp_password"
  string_value = random_password.sp.result
  scope        = databricks_secret_scope.storage.name
}

resource "databricks_secret" "sa_key" {
  key          = "sa_key"
  string_value = azurerm_storage_account.sa_blob.primary_access_key
  scope        = databricks_secret_scope.storage.name
}

resource "databricks_azure_blob_mount" "container" {
  container_name       = azurerm_storage_container.container.name
  storage_account_name = azurerm_storage_account.sa_blob.name
  mount_name           = "${azurerm_storage_account.sa_blob.name}_${azurerm_storage_container.container.name}"
  auth_type            = "ACCESS_KEY"
  token_secret_scope   = databricks_secret_scope.storage.name
  token_secret_key     = databricks_secret.sa_key.key
}

resource "databricks_azure_adls_gen2_mount" "filesystem" {
  container_name         = azurerm_storage_data_lake_gen2_filesystem.fs.name
  storage_account_name   = azurerm_storage_account.sa_adls.name
  mount_name             = "${azurerm_storage_account.sa_adls.name}_${azurerm_storage_data_lake_gen2_filesystem.fs.name}"
  tenant_id              = data.azurerm_client_config.c.tenant_id
  client_id              = azuread_application.app.application_id
  client_secret_scope    = databricks_secret_scope.storage.name
  client_secret_key      = databricks_secret.sp_password.key
  initialize_file_system = true
}