#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - curl

write_files:
  - path: /opt/elk/docker-compose.yml
    permissions: "0644"
    content: |
      services:
        elasticsearch:
          image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
          environment:
            - discovery.type=single-node
            - xpack.security.enabled=true
            - ELASTIC_PASSWORD=${kibana_password}
            - ES_JAVA_OPTS=-Xms2g -Xmx2g
          ports: ["9200:9200"]
          volumes: [esdata:/usr/share/elasticsearch/data]
          restart: unless-stopped

        kibana:
          image: docker.elastic.co/kibana/kibana:8.13.4
          depends_on: [elasticsearch]
          environment:
            - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
            - ELASTICSEARCH_USERNAME=kibana_system
            - ELASTICSEARCH_PASSWORD=${kibana_password}
          ports: ["5601:5601"]
          restart: unless-stopped

        # Forwarder: Filebeat agents on targets ship to 5044, Logstash
        # would normally process; for a teaching range we keep it simple
        # and have Filebeat write directly to ES (configured in the
        # target-side filebeat.yml).
      volumes:
        esdata:

runcmd:
  - cd /opt/elk && docker compose up -d
  - sleep 60
  # Set the kibana_system password to match
  - |
    until curl -sf -u "elastic:${kibana_password}" \
        -X POST -H 'Content-Type: application/json' \
        "http://localhost:9200/_security/user/kibana_system/_password" \
        -d "{\"password\":\"${kibana_password}\"}"; do
      sleep 5
    done
