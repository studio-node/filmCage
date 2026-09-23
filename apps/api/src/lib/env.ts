import 'dotenv/config';

function required(name: string): string {
  const value = process.env[name];
  if (!value || value.startsWith('your-') || value === 'change-me') {
    throw new Error(
      `Missing or placeholder value for required env var: ${name} (check .env against .env.example)`
    );
  }
  return value;
}

export const env = {
  port: Number(process.env.PORT ?? 8787),
  supabaseUrl: required('SUPABASE_URL'),
  supabaseServiceRoleKey: required('SUPABASE_SERVICE_ROLE_KEY'),
  webhookSharedSecret: required('WEBHOOK_SHARED_SECRET'),
  // Soft-optional: the server should still boot and be smoke-testable
  // before a real email provider is wired up.
  emailProvider: process.env.EMAIL_PROVIDER ?? 'resend',
  resendApiKey: process.env.RESEND_API_KEY ?? '',
  emailFrom: process.env.EMAIL_FROM ?? 'The Film Cage <noreply@example.edu>',
};
