#!/usr/bin/env bash
set -euo pipefail

MYSQL_NAMESPACE="${MYSQL_NAMESPACE:-mysql}"
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-postgres}"

decode_secret_value() {
  local namespace="$1"
  local name="$2"
  local key="$3"
  kubectl get secret "${name}" -n "${namespace}" -o "jsonpath={.data.${key}}" | base64 -d
}

query_mysql() {
  local sql="$1"
  local password
  password="$(decode_secret_value "${MYSQL_NAMESPACE}" mysql-secret root-password)"
  kubectl exec -n "${MYSQL_NAMESPACE}" mysql-0 -- \
    mysql -N -uroot "-p${password}" sourcedb -e "${sql}"
}

query_postgres() {
  local sql="$1"
  local password
  password="$(decode_secret_value "${POSTGRES_NAMESPACE}" postgres-secret postgres-password)"
  kubectl exec -n "${POSTGRES_NAMESPACE}" postgresql-0 -- \
    sh -c "PGPASSWORD='${password}' psql -U postgres -d targetdb -t -A -c \"${sql}\""
}

has_mismatch=0
tables=(users posts comments tags)

echo "== Row count comparison =="
for table in "${tables[@]}"; do
  mysql_count="$(query_mysql "SELECT COUNT(*) FROM ${table};" | tr -d '[:space:]')"
  postgres_count="$(query_postgres "SELECT COUNT(*) FROM ${table};" | tr -d '[:space:]')"
  status="OK"
  if [[ "${mysql_count}" != "${postgres_count}" ]]; then
    status="MISMATCH"
    has_mismatch=1
  fi
  printf "%-10s MySQL=%-8s PostgreSQL=%-8s %s\n" "${table}" "${mysql_count}" "${postgres_count}" "${status}"
done

echo
echo "== PostgreSQL integrity checks =="
checks=(
  "posts.user_id references users.id|SELECT COUNT(*) FROM posts p LEFT JOIN users u ON p.user_id = u.id WHERE u.id IS NULL;"
  "comments.post_id references posts.id|SELECT COUNT(*) FROM comments c LEFT JOIN posts p ON c.post_id = p.id WHERE p.id IS NULL;"
  "comments.user_id references users.id|SELECT COUNT(*) FROM comments c LEFT JOIN users u ON c.user_id = u.id WHERE u.id IS NULL;"
  "users required columns are not null|SELECT COUNT(*) FROM users WHERE id IS NULL OR username IS NULL OR email IS NULL;"
  "posts required columns are not null|SELECT COUNT(*) FROM posts WHERE id IS NULL OR user_id IS NULL OR title IS NULL;"
  "comments required columns are not null|SELECT COUNT(*) FROM comments WHERE id IS NULL OR post_id IS NULL OR user_id IS NULL OR content IS NULL;"
  "tags required columns are not null|SELECT COUNT(*) FROM tags WHERE id IS NULL OR name IS NULL;"
)

for item in "${checks[@]}"; do
  label="${item%%|*}"
  sql="${item#*|}"
  violations="$(query_postgres "${sql}" | tr -d '[:space:]')"
  status="OK"
  if [[ "${violations}" != "0" ]]; then
    status="FAIL"
    has_mismatch=1
  fi
  printf "%-45s violations=%-6s %s\n" "${label}" "${violations}" "${status}"
done

if [[ "${has_mismatch}" -ne 0 ]]; then
  exit 1
fi

echo
echo "CDC validation passed."
