-- kb_ontology_schema.sql
--
-- Durable store for the KB ontology graph (aviation_records_kg) admin
-- create/update capability. See terraform/cloudsql.tf's graphsvc_kb_writer
-- resource for the login this schema is granted to, and
-- classifier/src/loader/kb_source.py for the reader that consumes it.
--
-- Apply manually against the shared Cloud SQL instance as the zsynergy owner
-- (this repo has no migration framework — see terraform/CLAUDE.md). Idempotent
-- (IF NOT EXISTS) — safe to re-run.
--
-- After applying, run the GRANT block documented in terraform/cloudsql.tf's
-- graphsvc_kb_writer comment, then classifier/scripts/seed_kb_ontology_table.py
-- once to backfill from the existing graph_nodes.json/graph_edges.json.

CREATE TABLE IF NOT EXISTS kb_ontology_nodes (
  id          TEXT PRIMARY KEY,
  label       TEXT NOT NULL,
  properties  JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_by  TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS kb_ontology_edges (
  id          BIGSERIAL PRIMARY KEY,
  type        TEXT NOT NULL,
  from_id     TEXT NOT NULL REFERENCES kb_ontology_nodes(id) ON DELETE CASCADE,
  to_id       TEXT NOT NULL REFERENCES kb_ontology_nodes(id) ON DELETE CASCADE,
  properties  JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_by  TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (type, from_id, to_id)
);

CREATE INDEX IF NOT EXISTS kb_ontology_edges_from_id_idx ON kb_ontology_edges (from_id);
CREATE INDEX IF NOT EXISTS kb_ontology_edges_to_id_idx ON kb_ontology_edges (to_id);
