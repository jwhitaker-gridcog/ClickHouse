#!/usr/bin/env bash
# Tags: zookeeper

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# The hosts of `ON CLUSTER` execute a query without the user, unless `distributed_ddl_use_initial_user_and_roles` is
# enabled, and a partition value is evaluated where the command is executed. So a partition value of such a query must
# be a literal, or a tuple of literals, which needs no access to evaluate.

# Not the database of the test: it may be a `Replicated` one, which refuses `ON CLUSTER` on its hosts.
db="${CLICKHOUSE_DATABASE}_c"
user="u_${CLICKHOUSE_TEST_UNIQUE_NAME}"

cleanup()
{
    ${CLICKHOUSE_CLIENT} --query "DROP USER IF EXISTS ${user}"
    ${CLICKHOUSE_CLIENT} --query "DROP DATABASE IF EXISTS ${db} SYNC"
}

trap cleanup EXIT
cleanup

${CLICKHOUSE_CLIENT} <<EOF
CREATE DATABASE ${db} ENGINE = Atomic;
CREATE TABLE ${db}.secret (p UInt8) ENGINE = MergeTree ORDER BY p;
INSERT INTO ${db}.secret VALUES (2);
CREATE TABLE ${db}.src (p UInt8, v String) ENGINE = MergeTree PARTITION BY p ORDER BY v;
INSERT INTO ${db}.src VALUES (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd');
CREATE USER ${user};
GRANT ALTER DELETE, OPTIMIZE, SELECT ON ${db}.src TO ${user};
GRANT CLUSTER ON *.* TO ${user};
EOF

error_as_user()
{
    ${CLICKHOUSE_CLIENT} --user "${user}" --distributed_ddl_output_mode none --query "$1" 2>&1 | grep -o -m1 -E "ACCESS_DENIED|NOT_IMPLEMENTED"
}

partitions()
{
    ${CLICKHOUSE_CLIENT} --query "SELECT groupArray(p) FROM (SELECT DISTINCT p FROM ${db}.src ORDER BY p)"
}

echo "-- a partition value that is not a literal"
error_as_user "ALTER TABLE ${db}.src ON CLUSTER test_shard_localhost DROP PARTITION tuple((SELECT p FROM ${db}.secret LIMIT 1))"
error_as_user "ALTER TABLE ${db}.src ON CLUSTER test_shard_localhost DROP PARTITION tuple(toUInt8(2))"
error_as_user "OPTIMIZE TABLE ${db}.src ON CLUSTER test_shard_localhost PARTITION tuple((SELECT p FROM ${db}.secret LIMIT 1)) FINAL"
partitions

echo "-- a literal partition value"
${CLICKHOUSE_CLIENT} --user "${user}" --query "ALTER TABLE ${db}.src ON CLUSTER test_shard_localhost DROP PARTITION 2" > /dev/null && echo "OK"
${CLICKHOUSE_CLIENT} --user "${user}" --query "ALTER TABLE ${db}.src ON CLUSTER test_shard_localhost DROP PARTITION tuple(3)" > /dev/null && echo "OK"
${CLICKHOUSE_CLIENT} --user "${user}" --query "ALTER TABLE ${db}.src ON CLUSTER test_shard_localhost DROP PARTITION ID '4'" > /dev/null && echo "OK"
partitions
