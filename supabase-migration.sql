-- ============================================================================
-- CEDRO — Migration Supabase (rode no SQL Editor do projeto, uma vez)
-- Resolve: numeração atômica (SB-1), seed idempotente (SB-2),
--          numeração única por empresa, e segurança RLS (SB-5).
-- Seguro re-rodar: tudo é IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

-- ── 1. SB-2: UNIQUE(cnpj) em companies ──────────────────────────────────────
-- Fecha a corrida de seed em duas abas. Requer que todos os CNPJs do SEED
-- sejam distintos e não-nulos (já são, no index.html).
-- Se já existirem empresas duplicadas, limpe antes de criar o índice.
CREATE UNIQUE INDEX IF NOT EXISTS companies_cnpj_uniq ON companies (cnpj);

-- ── 2. counters: PK em company_id (necessário p/ upsert e RPC) ───────────────
-- Se a tabela counters ainda não tem PK/unique em company_id:
ALTER TABLE counters
  ADD CONSTRAINT counters_company_pk PRIMARY KEY (company_id);
-- (Se já existir PK, ignore o erro acima — comente esta linha.)

-- ── 3. SB-1: numeração atômica de orçamentos ─────────────────────────────────
-- Aloca o próximo número por empresa de forma atômica, mesmo sem linha prévia.
CREATE OR REPLACE FUNCTION next_quote_number(p_company uuid)
RETURNS int
LANGUAGE sql
SECURITY DEFINER
AS $$
  INSERT INTO counters (company_id, value) VALUES (p_company, 1)
  ON CONFLICT (company_id) DO UPDATE SET value = counters.value + 1
  RETURNING value;
$$;

-- numeração única por empresa (backstop; com a RPC, violação é quase impossível)
CREATE UNIQUE INDEX IF NOT EXISTS quotes_company_num_uniq ON quotes (company_id, num);

-- ============================================================================
-- 4. SB-5: SEGURANÇA — Row Level Security
-- ============================================================================
-- IMPORTANTE: a anon key é PÚBLICA (está no HTML). Sem RLS, qualquer um lê e
-- sobrescreve TODAS as empresas, carimbos (assinaturas!) e orçamentos.
--
-- PRIMEIRO, verifique o estado atual:
--   SELECT relname, relrowsecurity FROM pg_class
--   WHERE relname IN ('companies','stamps','quotes','counters');
--   SELECT * FROM pg_policies;
--
-- ── OPÇÃO A (rápida): exigir login para qualquer acesso ─────────────────────
-- Bloqueia anônimos. Qualquer usuário AUTENTICADO ainda vê tudo (sem multi-tenant).
-- Adequado se há um único time/dono usando o sistema.

ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE stamps    ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE counters  ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['companies','stamps','quotes','counters'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS auth_all ON %I;', t);
    EXECUTE format($p$
      CREATE POLICY auth_all ON %I
      FOR ALL
      USING (auth.role() = 'authenticated')
      WITH CHECK (auth.role() = 'authenticated');
    $p$, t);
  END LOOP;
END $$;

-- ── OPÇÃO B (isolamento real multi-tenant): por dono ────────────────────────
-- Use ESTA se diferentes usuários NÃO devem ver os dados uns dos outros.
-- Requer adicionar coluna owner e backfill. Descomente e adapte:
--
-- ALTER TABLE companies ADD COLUMN IF NOT EXISTS owner uuid DEFAULT auth.uid();
-- ALTER TABLE stamps    ADD COLUMN IF NOT EXISTS owner uuid DEFAULT auth.uid();
-- ALTER TABLE quotes    ADD COLUMN IF NOT EXISTS owner uuid DEFAULT auth.uid();
-- ALTER TABLE counters  ADD COLUMN IF NOT EXISTS owner uuid DEFAULT auth.uid();
-- -- backfill das linhas existentes com o uid do dono atual antes de aplicar políticas
-- -- depois, por tabela:
-- --   CREATE POLICY own_rows ON <t> FOR ALL
-- --     USING (owner = auth.uid()) WITH CHECK (owner = auth.uid());
--
-- NOTA: a seedCompanies() roda no client no primeiro load. Com a Opção B,
-- garanta que o INSERT/upsert respeite WITH CHECK (owner default = auth.uid()),
-- ou mova o seed para o servidor.

-- ── 5. (Recomendado) carimbos/assinaturas em Storage privado ────────────────
-- stamps.data hoje é um data-URL (base64) na tabela, legível com a anon key.
-- Para máxima proteção, mova para um bucket privado com RLS + signed URLs.
-- Isso é uma mudança maior — opcional, mas ideal para assinaturas sensíveis.
