#!/bin/sh
set -e

ACTION_ID=action-rsync
K_PREFIX=""

# Drone CI
if [ -n "$DRONE_BRANCH" ]; then
	K_PREFIX="PLUGIN_"
fi
if [ -n "$PLUGIN_VERBOSE" ]; then
	VERBOSE="$PLUGIN_VERBOSE"
fi
if [ -n "$PLUGIN_MODE" ]; then
	MODE="$PLUGIN_MODE"
fi
if [ -n "$PLUGIN_HOST" ]; then
	HOST="$PLUGIN_HOST"
fi
if [ -n "$PLUGIN_REMOTE_HOSTS" ]; then
	REMOTE_HOSTS="$PLUGIN_REMOTE_HOSTS"
fi
if [ -n "$PLUGIN_TARGET" ]; then
	TARGET="$PLUGIN_TARGET"
fi
if [ -n "$PLUGIN_KEY" ]; then
	KEY="$PLUGIN_KEY"
fi
if [ -n "$PLUGIN_PASSWORD" ]; then
	PASSWORD="$PLUGIN_PASSWORD"
fi
if [ -n "$PLUGIN_USER" ]; then
	USER="$PLUGIN_USER"
fi
if [ -n "$PLUGIN_PORT" ]; then
	PORT="$PLUGIN_PORT"
fi
if [ -n "$PLUGIN_SOURCE" ]; then
	SOURCE="$PLUGIN_SOURCE"
fi
if [ -n "$PLUGIN_ARGS" ]; then
	ARGS="$PLUGIN_ARGS"
fi
if [ -n "$PLUGIN_ARGS_MORE" ]; then
	ARGS_MORE="$PLUGIN_ARGS_MORE"
fi
if [ -n "$PLUGIN_SSH_ARGS" ]; then
	SSH_ARGS="$PLUGIN_SSH_ARGS"
fi
if [ -n "$PLUGIN_RUN_SCRIPT_ON" ]; then
	RUN_SCRIPT_ON="$PLUGIN_RUN_SCRIPT_ON"
fi
if [ -n "$PLUGIN_PRE_SCRIPT" ]; then
	PRE_SCRIPT="$PLUGIN_PRE_SCRIPT"
fi
if [ -n "$PLUGIN_POST_SCRIPT" ]; then
	POST_SCRIPT="$PLUGIN_POST_SCRIPT"
fi

# Github action
if [ -n "$GITHUB_WORKSPACE" ]; then
	cd "$GITHUB_WORKSPACE"
fi

if [ -z "$VERBOSE" ]; then
	VERBOSE=false
fi

__err=0
log() {
	if [ "$VERBOSE" = "true" ]; then
		printf "[$ACTION_ID] %s\n" "$*"
	fi
}
err() {
	__err=$((__err + 1))
	printf "[$ACTION_ID] %s\n" "$*" 1>&2
}
die() {
	err "$*"
	exit 1
}

if [ -z "$MODE" ]; then
	MODE=push
else
	MODE=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')

	case "$MODE" in
	push | pull | local) ;;
	*)
		die "Invalid \$${K_PREFIX}MODE. Must be one of [push, pull, local]"
		;;
	esac
fi

if [ -z "$REMOTE_HOSTS" ]; then
	if [ -z "$HOST" ]; then
		case "$MODE" in
		push | pull)
			die "Must specify \$${K_PREFIX}HOST or \$${K_PREFIX}REMOTE_HOSTS! (Remote host)"
			;;
		esac
	fi
	REMOTE_HOSTS="$HOST"
else
	REMOTE_HOSTS=$(printf "%s" "$REMOTE_HOSTS" | tr ',\r\n' ' ')
fi

if [ -z "$TARGET" ]; then
	die "Must specify \$${K_PREFIX}TARGET! (Target folder or file. If you set it as a file, must set \$${K_PREFIX}SOURCE as file too.)"
fi

if [ -z "$KEY" ]; then
	if [ -z "$PASSWORD" ]; then
		case "$MODE" in
		push | pull)
			die "Must provide either \$${K_PREFIX}KEY or \$${K_PREFIX}PASSWORD! (ssh private key or ssh password)"
			;;
		esac
	else
		log "Using \$${K_PREFIX}PASSWORD is less secure, please consider using \$${K_PREFIX}KEY instead."
	fi
fi

if [ -z "$USER" ]; then
	USER="root"
	case "$MODE" in
	push | pull)
		log "\$${K_PREFIX}USER not specified, using default: '$USER'."
		;;
	esac
fi

if [ -z "$PORT" ]; then
	PORT="22"
	case "$MODE" in
	push | pull)
		log "\$${K_PREFIX}PORT not specified, using default: $PORT."
		;;
	esac
fi

if [ -z "$SOURCE" ]; then
	SOURCE="./"
	log "\$${K_PREFIX}SOURCE not specified, using default folder: '$SOURCE'."
fi

if [ -z "$ARGS" ]; then
	ARGS="-azv --delete --exclude=/.git/ --exclude=/.github/"
	log "\$${K_PREFIX}ARGS not specified, using default rsync arguments: '$ARGS'."
fi

if [ -n "$ARGS_MORE" ]; then
	log "\$${K_PREFIX}ARGS_MORE specified, will append to \$${K_PREFIX}ARGS."
fi

if [ -z "$SSH_ARGS" ]; then
	SSH_ARGS="-p $PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=quiet"
	case "$MODE" in
	push | pull)
		log "\$${K_PREFIX}SSH_ARGS not specified, using default: '$SSH_ARGS'."
		;;
	esac
else
	log "You specified \$${K_PREFIX}SSH_ARGS, so \$${K_PREFIX}PORT will be ignored."
fi

if [ -z "$RUN_SCRIPT_ON" ]; then
	RUN_SCRIPT_ON=target
	log "\$${K_PREFIX}RUN_SCRIPT_ON not specified, using default: '$RUN_SCRIPT_ON'"
else
	RUN_SCRIPT_ON=$(echo "$RUN_SCRIPT_ON" | tr '[:upper:]' '[:lower:]')
fi

case "$RUN_SCRIPT_ON" in
local)
	REAL_RUN_SCRIPT_ON="$RUN_SCRIPT_ON"
	;;
remote)
	REAL_RUN_SCRIPT_ON="$RUN_SCRIPT_ON"
	if [ "$MODE" = "local" ]; then
		die "Invalid setup: cannot run scripts on remote when \$${K_PREFIX}MODE is 'local'."
	fi
	;;
source)
	if [ "$MODE" = "local" ]; then
		REAL_RUN_SCRIPT_ON=local
	elif [ "$MODE" = "push" ]; then
		REAL_RUN_SCRIPT_ON=local
	else
		REAL_RUN_SCRIPT_ON=remote
	fi
	;;
target)
	if [ "$MODE" = "local" ]; then
		REAL_RUN_SCRIPT_ON=local
	elif [ "$MODE" = "push" ]; then
		REAL_RUN_SCRIPT_ON=remote
	else
		REAL_RUN_SCRIPT_ON=local
	fi
	;;
*)
	die "Invalid \$${K_PREFIX}RUN_SCRIPT_ON, must be one of [local, remote, source, target]"
	;;
esac

# Prepare
if [ -n "$KEY" ]; then
	case "$MODE" in
	push | pull)
		mkdir -p "$HOME/.ssh"
		echo "$KEY" | tr -d '\r' >"$HOME/.ssh/key"
		chmod 600 "$HOME/.ssh/key"
		;;
	esac
	cmd_ssh=$(printf "ssh -i %s %s" "$HOME/.ssh/key" "$SSH_ARGS")
elif [ -n "$PASSWORD" ]; then
	export SSHPASS="$PASSWORD"
	cmd_ssh=$(printf "sshpass -e ssh %s" "$SSH_ARGS")
fi

case "$MODE" in
push | pull)
	if [ -n "$KEY" ]; then
		cmd_rsync=$(printf "rsync %s %s -e '%s'" "$ARGS" "$ARGS_MORE" "$cmd_ssh")
	elif [ -n "$PASSWORD" ]; then
		cmd_rsync=$(printf "sshpass -e rsync %s %s -e 'ssh %s'" "$ARGS" "$ARGS_MORE" "$SSH_ARGS")
	fi
	;;
local)
	cmd_rsync=$(printf "rsync %s %s" "$ARGS" "$ARGS_MORE")
	;;
esac
case "$REAL_RUN_SCRIPT_ON" in
local)
	cmd_rsync_script=$(printf "rsync -av")
	;;
remote)
	if [ -n "$KEY" ]; then
		cmd_rsync_script=$(printf "rsync -avz -e '%s'" "$cmd_ssh")
	elif [ -n "$PASSWORD" ]; then
		cmd_rsync_script=$(printf "sshpass -e rsync -avz -e 'ssh %s'" "$SSH_ARGS")
	fi
	;;
esac

run_script() {
	name="$1"
	src="$2"

	log "========== $name starting =========="
	if [ "$REAL_RUN_SCRIPT_ON" = "remote" ]; then
		dest=$(eval "$cmd_ssh" "$USER@$HOST" 'mktemp')
	else
		dest=$(mktemp)
	fi

	if [ "$REAL_RUN_SCRIPT_ON" = "remote" ]; then
		eval "$cmd_rsync_script" "$src" "$USER@$HOST:$dest"
	else
		eval "$cmd_rsync_script" "$src" "$dest"
	fi
	log "========== $name sent =========="
	if [ "$REAL_RUN_SCRIPT_ON" = "remote" ]; then
		eval "$cmd_ssh" "$USER@$HOST" "sh $dest"
	else
		sh "$dest"
	fi
	log "========== $name executed =========="
	if [ "$REAL_RUN_SCRIPT_ON" = "remote" ]; then
		eval "$cmd_ssh" "$USER@$HOST" "rm $dest"
	else
		rm "$dest"
	fi
	log "========== $name removed =========="
}

__run_count=0
run_once() {
	if [ -n "$PRE_SCRIPT" ]; then
		pre_src=$(mktemp)
		printf "%s\n" "$PRE_SCRIPT" >"$pre_src"
		run_script "Pre script" "$pre_src"
	fi
	case "$MODE" in
	push)
		eval "$cmd_rsync" "$SOURCE" "$USER@$HOST:$TARGET"
		;;
	pull)
		eval "$cmd_rsync" "$USER@$HOST:$SOURCE" "$TARGET"
		;;
	local)
		eval "$cmd_rsync" "$SOURCE" "$TARGET"
		;;
	esac
	if [ -n "$POST_SCRIPT" ]; then
		post_src=$(mktemp)
		printf "%s\n" "$POST_SCRIPT" >"$post_src"
		run_script "Post script" "$post_src"
	fi
	__run_count=$((__run_count + 1))
}

# Execute
if [ "$MODE" = "local" ]; then
	run_once
else
	log "Starting execution with mode '$MODE' on host(s): $REMOTE_HOSTS"
	for h in $REMOTE_HOSTS; do
		HOST="$h"
		run_once
	done
fi

# final handler
if [ "$__run_count" -eq 0 ]; then
	err "No successful execution was detected"
fi
if [ "$__err" -ne 0 ]; then
	exit 1
fi
