#!/bin/sh

## On docker compose
#docker compose --project-name web exec nginx nginx -s reload

## On docker swarm
docker exec $(docker ps -q -f name=nginx) nginx -s reload