import express from 'express';
import { env } from './lib/env.js';
import { supabaseAdmin } from './lib/supabaseAdmin.js';
import { webhooksRouter } from './routes/webhooks.js';

const app = express();
app.use(express.json());

// Proves the service-role connection to Supabase actually works —
// the backend equivalent of the frontend's catalog-page smoke test.
app.get('/health', async (_req, res) => {
  const { error } = await supabaseAdmin.from('categories').select('id').limit(1);
  if (error) {
    res.status(500).json({ ok: false, supabase: 'unreachable', error: error.message });
    return;
  }
  res.json({ ok: true, supabase: 'connected' });
});

app.use('/webhooks', webhooksRouter);

app.listen(env.port, () => {
  console.log(`filmcage-api listening on :${env.port}`);
});
