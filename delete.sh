#!/bin/bash

docker stack rm microblog

docker compose -f docker-compose-registry.yml down
