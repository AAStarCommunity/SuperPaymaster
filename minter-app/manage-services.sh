#!/bin/bash

# Function to start all services
start_services() {
    echo "Starting all services..."

    # Start the backend server
    echo "Starting backend server on port 3001..."
    (cd backend && node server.js &)

    # Start the frontend server
    echo "Starting frontend server on port 5173..."
    (cd frontend && pnpm dev &)

    echo "All services started."
}

# Function to stop all services
stop_services() {
    echo "Stopping all services..."
    # Kill all node processes, which should include the backend and the vite frontend
    killall -9 node
    echo "Services stopped."
}

# Main script logic
case "$1" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        stop_services
        sleep 2 # Give a moment for ports to be released
        start_services
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
