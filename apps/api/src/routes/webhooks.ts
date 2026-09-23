import { Router } from 'express';
import { supabaseAdmin } from '../lib/supabaseAdmin.js';
import { env } from '../lib/env.js';
import { sendEmail } from '../lib/email.js';

export const webhooksRouter = Router();

interface NotificationRecord {
  id: string;
  user_id: string;
  type: string;
  title: string;
  body: string | null;
  channel: 'in_app' | 'email';
}

interface SupabaseWebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  schema: string;
  record: NotificationRecord | null;
  old_record: NotificationRecord | null;
}

// Configure this as a Supabase Database Webhook (Database -> Webhooks)
// on INSERT into public.notifications, with a custom header
// `x-webhook-secret: <WEBHOOK_SHARED_SECRET>` so only Supabase can call it.
webhooksRouter.post('/notifications', async (req, res) => {
  const secret = req.header('x-webhook-secret');
  if (secret !== env.webhookSharedSecret) {
    res.status(401).json({ error: 'invalid webhook secret' });
    return;
  }

  const payload = req.body as SupabaseWebhookPayload;

  // Ack immediately — Supabase retries slow/non-2xx responses, and a
  // slow email provider shouldn't turn into a retry storm. Everything
  // after this is fire-and-forget (v1 simplification: no durable queue,
  // so a mid-send crash loses that one email rather than retrying it).
  res.status(200).json({ received: true });

  if (payload.type !== 'INSERT' || payload.table !== 'notifications') return;
  const record = payload.record;
  if (!record || record.channel !== 'email') return;

  try {
    const { data: user, error } = await supabaseAdmin
      .from('users')
      .select('email, full_name')
      .eq('id', record.user_id)
      .single();

    if (error || !user?.email) {
      console.error(`[webhooks] no email on file for user ${record.user_id}`, error?.message);
      return;
    }

    await sendEmail({
      to: user.email,
      subject: record.title,
      html: renderNotificationEmail(record, user.full_name),
    });
    console.log(`[webhooks] sent "${record.type}" email to ${user.email}`);
  } catch (err) {
    console.error('[webhooks] failed to send notification email:', (err as Error).message);
  }
});

function renderNotificationEmail(record: NotificationRecord, fullName: string): string {
  return `
    <div style="font-family: system-ui, sans-serif; max-width: 480px; margin: 0 auto;">
      <h2>${escapeHtml(record.title)}</h2>
      <p>Hi ${escapeHtml(fullName ?? 'there')},</p>
      <p>${escapeHtml(record.body ?? '')}</p>
      <p style="color: #666; font-size: 0.85rem;">The Film Cage</p>
    </div>
  `;
}

function escapeHtml(s: string): string {
  const map: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  };
  return s.replace(/[&<>"']/g, (c) => map[c]!);
}
