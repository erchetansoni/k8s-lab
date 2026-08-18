#!/bin/bash

# ==============================================================================
# Script to Start, Stop, and Check Status of cloud-provider-kind
# ==============================================================================

PID_FILE="/tmp/cloud-provider-kind.pid"
LOG_FILE="/tmp/cloud-provider-kind.log"

# Find binary in PATH or Go bin directory
BIN_NAME="cloud-provider-kind"
if ! command -v "$BIN_NAME" &> /dev/null; then
    if [ -f "$HOME/go/bin/cloud-provider-kind" ]; then
        BIN_NAME="$HOME/go/bin/cloud-provider-kind"
    elif [ -f "$HOME/go/bin/cloud-provider-kind.exe" ]; then
        BIN_NAME="$HOME/go/bin/cloud-provider-kind.exe"
    else
        echo "❌ Error: cloud-provider-kind binary not found!"
        echo "   Install it with: go install sigs.k8s.io/cloud-provider-kind@latest"
        exit 1
    fi
fi

is_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1 || pgrep -f "cloud-provider-kind" > /dev/null 2>&1; then
            return 0
        fi
    fi
    if pgrep -f "cloud-provider-kind" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

start() {
    if is_running; then
        echo "⚠️  cloud-provider-kind is already running."
        status
        return
    fi

    echo "🚀 Starting cloud-provider-kind in background..."
    nohup "$BIN_NAME" --enable-default-ingress=false -v 2 > "$LOG_FILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PID_FILE"
    sleep 1

    if is_running; then
        echo "✅ cloud-provider-kind started successfully (PID: $PID)"
        echo "📄 Logs: $LOG_FILE"
    else
        echo "❌ Failed to start cloud-provider-kind. Check logs at $LOG_FILE"
        cat "$LOG_FILE"
    fi
}

stop() {
    if ! is_running; then
        echo "ℹ️  cloud-provider-kind is not running."
        rm -f "$PID_FILE"
        return
    fi

    echo "🛑 Stopping cloud-provider-kind..."
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        kill -TERM "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    pkill -TERM -f "cloud-provider-kind" 2>/dev/null || true
    sleep 1
    echo "✅ cloud-provider-kind stopped."
}

status() {
    if is_running; then
        PID=$(pgrep -f "cloud-provider-kind" | head -n 1)
        echo "🟢 cloud-provider-kind is RUNNING (PID: $PID)"
        echo "📄 Log file: $LOG_FILE"
    else
        echo "🔴 cloud-provider-kind is STOPPED"
    fi
}

logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -n 30 -f "$LOG_FILE"
    else
        echo "No log file found at $LOG_FILE"
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        sleep 1
        start
        ;;
    status)
        status
        ;;
    logs)
        logs
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
