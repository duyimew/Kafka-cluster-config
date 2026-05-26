#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
COUNT=1
WAIT_SECONDS=5
PREFIX="all_demo"
VALIDATE=1

usage() {
  cat <<'EOF'
Usage:
  bash scripts/demo-all-tables.sh <action> [--count N] [--wait SECONDS] [--prefix NAME] [--no-validate]

Actions:
  insert    Insert N linked users, posts, comments and N tags.
  update    Update N latest demo rows in users, posts, comments and tags.
  delete    Delete N latest demo rows in FK-safe order: comments -> posts -> users, plus tags.
  mixed     Run insert, update, then delete one demo set.
  status    Show demo row counts and samples in MySQL/PostgreSQL.

Examples:
  bash scripts/demo-all-tables.sh insert --count 3 --prefix report_all
  bash scripts/demo-all-tables.sh update --count 2 --prefix report_all
  bash scripts/demo-all-tables.sh delete --count 1 --prefix report_all
  bash scripts/demo-all-tables.sh mixed --count 2 --prefix report_all
EOF
}

if [[ -z "${ACTION}" ]]; then
  usage
  exit 1
fi
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      COUNT="${2:?Missing value for --count}"
      shift 2
      ;;
    --wait)
      WAIT_SECONDS="${2:?Missing value for --wait}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:?Missing value for --prefix}"
      shift 2
      ;;
    --no-validate)
      VALIDATE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || [[ "${COUNT}" -lt 1 ]]; then
  echo "--count must be a positive integer"
  exit 1
fi

if ! [[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "--wait must be a non-negative integer"
  exit 1
fi

if ! [[ "${PREFIX}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "--prefix may only contain letters, numbers, and underscores"
  exit 1
fi

decode_secret_value() {
  local namespace="$1"
  local name="$2"
  local key="$3"
  kubectl get secret "${name}" -n "${namespace}" -o "jsonpath={.data.${key}}" | base64 -d
}

mysql_password() {
  decode_secret_value mysql mysql-secret root-password
}

postgres_password() {
  decode_secret_value postgres postgres-secret postgres-password
}

exec_mysql() {
  local sql="$1"
  local password
  password="$(mysql_password)"
  kubectl exec -n mysql mysql-0 -- mysql -uroot "-p${password}" sourcedb -e "${sql}"
}

query_mysql() {
  local sql="$1"
  local password
  password="$(mysql_password)"
  kubectl exec -n mysql mysql-0 -- mysql -N -B -uroot "-p${password}" sourcedb -e "${sql}"
}

query_postgres() {
  local sql="$1"
  local password
  password="$(postgres_password)"
  kubectl exec -n postgres postgresql-0 -- \
    sh -c "PGPASSWORD='${password}' psql -U postgres -d targetdb -t -A -F '|' -c \"${sql}\""
}

wait_for_cdc() {
  local label="${1:-CDC propagation}"
  if [[ "${WAIT_SECONDS}" -gt 0 ]]; then
    echo "Waiting ${WAIT_SECONDS}s for ${label}..."
    sleep "${WAIT_SECONDS}"
  fi
}

validate_if_enabled() {
  if [[ "${VALIDATE}" -eq 1 ]]; then
    echo
    bash scripts/validate-cdc.sh
  fi
}

mysql_count() {
  local table="$1"
  local where_clause="$2"
  query_mysql "SELECT COUNT(*) FROM ${table} WHERE ${where_clause};" | tr -d '[:space:]'
}

postgres_count() {
  local table="$1"
  local where_clause="$2"
  query_postgres "SELECT COUNT(*) FROM ${table} WHERE ${where_clause};" | tr -d '[:space:]'
}

show_counts() {
  echo "Demo rows with prefix '${PREFIX}':"
  printf "  users   MySQL=%-5s PostgreSQL=%s\n" \
    "$(mysql_count users "username LIKE '${PREFIX}_user_%'")" \
    "$(postgres_count users "username LIKE '${PREFIX}_user_%'")"
  printf "  posts   MySQL=%-5s PostgreSQL=%s\n" \
    "$(mysql_count posts "title LIKE '${PREFIX}_post_%'")" \
    "$(postgres_count posts "title LIKE '${PREFIX}_post_%'")"
  printf "  comments MySQL=%-5s PostgreSQL=%s\n" \
    "$(mysql_count comments "content LIKE '${PREFIX}_comment_%'")" \
    "$(postgres_count comments "content LIKE '${PREFIX}_comment_%'")"
  printf "  tags    MySQL=%-5s PostgreSQL=%s\n" \
    "$(mysql_count tags "name LIKE '${PREFIX}_tag_%'")" \
    "$(postgres_count tags "name LIKE '${PREFIX}_tag_%'")"
}

show_samples() {
  echo
  echo "PostgreSQL demo users:"
  query_postgres "SELECT id, username, full_name, status FROM users WHERE username LIKE '${PREFIX}_user_%' ORDER BY id DESC LIMIT 5;"
  echo
  echo "PostgreSQL demo posts:"
  query_postgres "SELECT id, user_id, title, status, view_count FROM posts WHERE title LIKE '${PREFIX}_post_%' ORDER BY id DESC LIMIT 5;"
  echo
  echo "PostgreSQL demo comments:"
  query_postgres "SELECT id, post_id, user_id, content FROM comments WHERE content LIKE '${PREFIX}_comment_%' ORDER BY id DESC LIMIT 5;"
  echo
  echo "PostgreSQL demo tags:"
  query_postgres "SELECT id, name, post_count FROM tags WHERE name LIKE '${PREFIX}_tag_%' ORDER BY id DESC LIMIT 5;"
}

insert_demo() {
  local run_id i username title tag_name
  run_id="$(date +%Y%m%d%H%M%S)"

  echo "Inserting ${COUNT} users..."
  for ((i = 1; i <= COUNT; i++)); do
    username="${PREFIX}_user_${run_id}_${i}"
    exec_mysql "INSERT INTO users (username, email, full_name, status) VALUES ('${username}', '${username}@example.lab', 'All Table Demo User ${i}', 'active');"
  done
  wait_for_cdc "users"

  echo "Inserting ${COUNT} posts linked to demo users..."
  for ((i = 1; i <= COUNT; i++)); do
    username="${PREFIX}_user_${run_id}_${i}"
    title="${PREFIX}_post_${run_id}_${i}"
    exec_mysql "INSERT INTO posts (user_id, title, content, status, view_count) SELECT id, '${title}', 'All table demo post ${i}', 'published', ${i} FROM users WHERE username='${username}';"
  done
  wait_for_cdc "posts"

  echo "Inserting ${COUNT} comments linked to demo posts/users..."
  for ((i = 1; i <= COUNT; i++)); do
    username="${PREFIX}_user_${run_id}_${i}"
    title="${PREFIX}_post_${run_id}_${i}"
    exec_mysql "INSERT INTO comments (post_id, user_id, content) SELECT p.id, u.id, '${PREFIX}_comment_${run_id}_${i}' FROM posts p JOIN users u ON u.id=p.user_id WHERE p.title='${title}' AND u.username='${username}';"
  done
  wait_for_cdc "comments"

  echo "Inserting ${COUNT} tags..."
  for ((i = 1; i <= COUNT; i++)); do
    tag_name="${PREFIX}_tag_${run_id}_${i}"
    exec_mysql "INSERT INTO tags (name, post_count) VALUES ('${tag_name}', ${i});"
  done
  wait_for_cdc "tags"
}

update_demo() {
  echo "Updating ${COUNT} latest demo rows in all 4 tables..."
  exec_mysql "UPDATE users SET full_name=CONCAT(full_name, ' updated'), status='inactive' WHERE username LIKE '${PREFIX}_user_%' ORDER BY id DESC LIMIT ${COUNT};"
  exec_mysql "UPDATE posts SET title=CONCAT(title, '_updated'), status='archived', view_count=view_count+100 WHERE title LIKE '${PREFIX}_post_%' ORDER BY id DESC LIMIT ${COUNT};"
  exec_mysql "UPDATE comments SET content=CONCAT(content, '_updated') WHERE content LIKE '${PREFIX}_comment_%' ORDER BY id DESC LIMIT ${COUNT};"
  exec_mysql "UPDATE tags SET post_count=post_count+100 WHERE name LIKE '${PREFIX}_tag_%' ORDER BY id DESC LIMIT ${COUNT};"
  wait_for_cdc "updates"
}

delete_demo() {
  echo "Deleting ${COUNT} latest demo rows in FK-safe order..."
  exec_mysql "DELETE FROM comments WHERE content LIKE '${PREFIX}_comment_%' ORDER BY id DESC LIMIT ${COUNT};"
  wait_for_cdc "comment deletes"
  exec_mysql "DELETE FROM posts WHERE title LIKE '${PREFIX}_post_%' ORDER BY id DESC LIMIT ${COUNT};"
  wait_for_cdc "post deletes"
  exec_mysql "DELETE FROM users WHERE username LIKE '${PREFIX}_user_%' ORDER BY id DESC LIMIT ${COUNT};"
  wait_for_cdc "user deletes"
  exec_mysql "DELETE FROM tags WHERE name LIKE '${PREFIX}_tag_%' ORDER BY id DESC LIMIT ${COUNT};"
  wait_for_cdc "tag deletes"
}

run_action() {
  echo "Action=${ACTION} Count=${COUNT} Prefix=${PREFIX}"
  echo
  echo "Before:"
  show_counts
  echo

  case "${ACTION}" in
    insert)
      insert_demo
      ;;
    update)
      update_demo
      ;;
    delete)
      delete_demo
      ;;
    mixed)
      insert_demo
      update_demo
      delete_demo
      ;;
  esac

  echo
  echo "After:"
  show_counts
  show_samples
  validate_if_enabled
}

case "${ACTION}" in
  insert|update|delete|mixed)
    run_action
    ;;
  status)
    show_counts
    show_samples
    ;;
  *)
    usage
    exit 1
    ;;
esac
