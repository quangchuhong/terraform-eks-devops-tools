# SonarQube backend: database "sonarqube" on the shared GitLab RDS PostgreSQL,
# plus the secrets the SonarQube chart (helm-install/sonarqube/sonarqube) reads.
# The chart itself is installed with the helm CLI (see README).

locals {
  sonarqube_namespace = "sonarqube"
  sonarqube_db_name   = "sonarqube"
  sonarqube_db_user   = "sonarqube"
}

resource "random_password" "sonarqube_db" {
  length  = 32
  special = false
}

resource "random_password" "sonarqube_monitoring" {
  length  = 32
  special = false
}

resource "kubernetes_namespace_v1" "sonarqube" {
  metadata {
    name = local.sonarqube_namespace
  }
  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "sonarqube_jdbc" {
  metadata {
    name      = "sonarqube-jdbc"
    namespace = kubernetes_namespace_v1.sonarqube.metadata[0].name
  }
  data = {
    "jdbc-password" = random_password.sonarqube_db.result
  }
}

resource "kubernetes_secret_v1" "sonarqube_monitoring" {
  metadata {
    name      = "sonarqube-monitoring"
    namespace = kubernetes_namespace_v1.sonarqube.metadata[0].name
  }
  data = {
    "passcode" = random_password.sonarqube_monitoring.result
  }
}

# The RDS instance is private, so the role and database are created from inside
# the cluster by a one-off Job that logs in as the RDS master user. It runs in the
# gitlab namespace, which already holds the master password secret.
resource "kubernetes_secret_v1" "sonarqube_db_bootstrap" {
  metadata {
    name      = "sonarqube-db-bootstrap"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    "password" = random_password.sonarqube_db.result
  }
}

resource "kubernetes_job_v1" "sonarqube_db_bootstrap" {
  metadata {
    name      = "sonarqube-db-bootstrap"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }

  spec {
    backoff_limit = 4

    template {
      metadata {}
      spec {
        restart_policy = "Never"

        container {
          name    = "psql"
          image   = "postgres:17-alpine"
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -e
            psql -v ON_ERROR_STOP=1 -v pw="$SONAR_PASSWORD" <<'SQL'
            SELECT set_config('bootstrap.pw', :'pw', false);
            DO $$
            BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.sonarqube_db_user}') THEN
                EXECUTE format('CREATE ROLE ${local.sonarqube_db_user} LOGIN PASSWORD %L', current_setting('bootstrap.pw'));
              ELSE
                EXECUTE format('ALTER ROLE ${local.sonarqube_db_user} LOGIN PASSWORD %L', current_setting('bootstrap.pw'));
              END IF;
            END
            $$;
            GRANT ${local.sonarqube_db_user} TO CURRENT_USER;
            SELECT 'CREATE DATABASE ${local.sonarqube_db_name} OWNER ${local.sonarqube_db_user}'
            WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${local.sonarqube_db_name}')\gexec
            SQL
          EOT
          ]

          env {
            name  = "PGHOST"
            value = aws_db_instance.gitlab.address
          }
          env {
            name  = "PGPORT"
            value = tostring(aws_db_instance.gitlab.port)
          }
          env {
            name  = "PGDATABASE"
            value = aws_db_instance.gitlab.db_name
          }
          env {
            name  = "PGUSER"
            value = aws_db_instance.gitlab.username
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.gitlab_postgresql.metadata[0].name
                key  = "postgresql-password"
              }
            }
          }
          env {
            name = "SONAR_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.sonarqube_db_bootstrap.metadata[0].name
                key  = "password"
              }
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
    update = "5m"
  }
}

output "sonarqube_jdbc_url" {
  description = "JDBC URL for helm-install/sonarqube (--set jdbcOverwrite.jdbcUrl=...)"
  value       = "jdbc:postgresql://${aws_db_instance.gitlab.address}:${aws_db_instance.gitlab.port}/${local.sonarqube_db_name}?sslmode=require"
}
