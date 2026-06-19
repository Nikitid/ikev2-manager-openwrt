#!/bin/sh
# Routing invariants shared by apply, doctor and operational self-tests.

forward_chain_ok() {
	nft list chain inet fw4 forward 2>/dev/null | grep -q 'jump forward_'
}

ensure_forward_chain() {
	forward_chain_ok && return 0
	fw4 -q reload || return 1
	forward_chain_ok
}

ensure_ipv6_failfast() {
	ip -6 route show default 2>/dev/null | grep -q . && return 0
	ip -6 route replace unreachable default metric 2147483647 2>/dev/null || true
}

failclosed_check() (
	table='pbr_ikev2out'
	test_slot=$(( $$ % 1000 ))
	test_table=$((49000 + test_slot))
	test_mark='0x00fe0000'
	test_mask='0x00ff0000'
	test_priority=$((10000 + test_slot))
	test_ip='203.0.113.77'
	test_output="/tmp/ikev2-failclosed-check-$$"

	ip -4 route show table "$table" 2>/dev/null |
		grep -Eq '^unreachable default( |$)' || return 1

	cleanup_failclosed_check() {
		ip -4 rule del priority "$test_priority" 2>/dev/null || true
		ip -4 route flush table "$test_table" 2>/dev/null || true
		rm -f "$test_output"
	}
	cleanup_failclosed_check
	trap cleanup_failclosed_check EXIT INT TERM
	ip -4 route add unreachable default metric 32767 table "$test_table"
	ip -4 rule add priority "$test_priority" \
		fwmark "$test_mark/$test_mask" lookup "$test_table"

	if ip -4 route get "$test_ip" mark "$test_mark" >"$test_output" 2>&1; then
		cleanup_failclosed_check
		rm -f "$test_output"
		return 1
	fi
	grep -qi 'unreachable' "$test_output"
	result=$?
	rm -f "$test_output"
	cleanup_failclosed_check
	return "$result"
)
