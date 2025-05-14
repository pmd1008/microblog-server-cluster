#!/bin/bash

docker stack rm -f microblog

docker compose -f docker-compose-registry.yml down
