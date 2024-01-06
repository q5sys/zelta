#!/usr/bin/awk -f
#
# zpull - replicates a snapshot and its descendants
#
# usage: zpull [user@][host:]source/dataset [user@][host:]target/dataset
#
# requires: zmatch
#
# After using zmatch to identify out-of-date snapshots on the target, zpull creates
# individual replication streams for a snapshot and its children. zpull is useful for
# migrations in that it will recursively replicate the latest parent snapshot and its
# children, unlike the "zfs send -R" option.
#
# If called with the environmental variable ZELTA_PIPE=1, zpull reports an abbreviated
# output for reporting:
#
# 	received_streams, total_bytes, time, error
#
# Additional flags can be set with the environmental variables ZPULL_SEND_FLAGS,
# ZPULL_RECV_FLAGS, and ZPULL_I_FLAGS (for incremental streams only).
#
# Note that as zpull is used as a backup and migration tool, the default behavior for new
# replicas is to only copy the latest snapshots from the source heirarchy, while the
# behavior for updating existing replicas is to copy intermediate snapshots. You can use
# "ZPULL_SEND_FLAGS=R" to bootstrap a new backup repository to keep backup history. Use
# "ZPULL_I_FLAGS=i" to only copy the latest snapshot.

function usage(error) {
	if (error) { print error | "cat 1>&2" }
	if (! ZELTA_PIPE) print "usage: zelta pull [-j] [user@][host:]source/dataset [user@][host:]target/dataset"
	exit 1
}

function env(env_name, var_default) {
	return ( (env_name in ENVIRON) ? ENVIRON[env_name] : var_default )
}

function q(s) { return "\'"s"\'" }

function get_dataset(dataset_string, dataset_array) {
	i = split(dataset_string, arr, /[@:]/)
	dataset_array["dataset"] = arr[i--]
	if (i) dataset_array["host"] = arr[i--]
	if (i) dataset_array["user"] = arr[i]
}

function opt_var() {
	var = ($0 ? $0 : ARGV[++i])
	$0 = ""
	return var
}

function get_options() {
	for (i=1;i<ARGC;i++) {
		$0 = ARGV[i]
		if (gsub(/^-/,"")) {
			if (gsub(/j/,"")) JSON++
			if (gsub(/R/,"")) c["REPLICATE_NEW"] = 1
			if (gsub(/d/,"")) c["DEPTH"] = opt_var()
			if (/./) {
				usage("unkown options: " $0)
			}
		} else if (target) {
			usage("too many options: " $0)
		} else if (source) target = $0
		else source = $0
	}
	if (! target) usage()
	get_dataset(source, source_info)
	get_dataset(target, target_info)
}
	       
function load_config() {
	ZELTA_CONFIG = env("ZELTA_CONFIG", "/usr/local/etc/zelta/zelta.conf")
	FS = "[: \t]+";
	while ((getline < ZELTA_CONFIG)>0) {
		if (split($0, arr, "#")) {
			$0 = arr[1]
		}
		gsub(/[ \t]+$/, "", $0)
		if (/^[^ ]+: +[^ ]/) {
			c[$1] = $2
		}
	}
	ZELTA_PIPE = env("ZELTA_PIPE", 0)
	get_options()
	send_flags = c["REPLICATE_NEW"] ? "LcpR" : "Lcp"
	send_flags = "send -P" env("ZPULL_SEND_FLAGS", send_flags) " "
	recv_flags = c["RECEIVE_FLAGS"] ? c["RECEIVE_FLAGS"] : "u"
	recv_flags = "receive -v" env("ZPULL_RECV_FLAGS", recv_flags) " "
	intr_flags = c["INTERMEDIATE"] ? "I" : "i"
	intr_flags = "-" env("ZPULL_I_FLAGS", intr_flags) " "
	recurse = (send_flags ~ /R/) ? 1 :0
	zmatch = "ZELTA_PIPE=1 /usr/bin/time zmatch " q(source) " " q(target)
	if (c["DEPTH"] && !recurse) {
		zmatch = "ZELTA_DEPTH=" c["DEPTH"] " " zmatch
	}
}

function zfs_command(vol_str) {
	if (split(vol_str, vol_arr, ":") == 2) {
		cmdpre = "ssh " vol_arr[1] " "
		volume = vol_arr[2];
	} else {
		cmdpre = ""
		volume = vol_arr[1]
	}
    zfs[vol_str] = cmdpre "zfs "
    vol[vol_str] = volume
    return zfs[vol_str]
}

function h_num(num) {
	suffix = "B"
	divisors = "KMGTPE"
	for (i = 1; i <= length(divisors) && num >= 1024; i++) {
		num /= 1024
		suffix = substr(divisors, i, 1)
	}
	return int(num) suffix
}

BEGIN {
	FS="\t"
	load_config()
	error_code = 0

	zfs_send_command = zfs_command(source) send_flags
	zfs_receive_command = zfs_command(target) recv_flags
	time_start = systime()
	while (zmatch " 2>&1" |getline) {
		if (/error/) {
			error_code = 1
			continue
		} else if ($3 == "real") {
			total_time = $2
			continue
		} else if (! /@/) {
			if (! $0 == $1) {
				print "error: " $0 | "cat 1>&2"
				if (ZELTA_PIPE) { print "0 0 0 3" }
				exit 1
			}
			zfs_create_command = zfs_command(target) "create -up " q($1) " >/dev/null 2>&1"
			if (system(zfs_create_command)) {
				if (ZELTA_PIPE) { print "0 0 0 4" }
				exit 1
			} else if (! ZELTA_PIPE) { print "created parent dataset(s)" }
			continue
		}
		num_streams++
		if ($3) {
			rpl_cmd[++rpl_num] = zfs_send_command intr_flags q($1) " " q($2) " | " zfs_receive_command q($3)
		} else {
			rpl_cmd[++rpl_num] = zfs_send_command q($1) " | " zfs_receive_command q($2)
		}
	}

	if (!num_streams) { 
		if (ZELTA_PIPE) { print "0 0 " total_time " " error_code }
		else { print "nothing to replicate" }
		exit error_code
	}

	FS = "[ \t]+";
	received_streams = 0
	total_bytes = 0
	for (i = 1; i <= rpl_num; i++) {
		full_cmd = "/usr/bin/time sh -c '" rpl_cmd[i] "' 2>&1"
		while (full_cmd | getline) {
			if ($1 == "incremental" || $1 == "full") { sent_streams++ }
			else if ($1 == "received") { received_streams++ }
			else if ($1 == "size") { total_bytes += $2 }
			else if ($3 == "real") { total_time += $2 }
			else if (/cannot/ || !/stream/) {
				print "error: " $0 | "cat 1>&2"
				error_code = 2
			}

		}
		if (recurse) { break } # If -R is given, skip manual descendants
	}

	# Negative errors show the number of missed streams, otherwise show error code
	error = received_streams - sent_streams
	if (! error) { error = error_code }
	if (ZELTA_PIPE) {
		print received_streams, total_bytes, total_time, error
	} else {
		print received_streams " streams received, " h_num(total_bytes) " copied in " total_time " seconds"
		if (error != 0) { print "error: " sent_streams " total" }
	}
	exit error_code
}
