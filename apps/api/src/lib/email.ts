import { Resend } from 'resend';
import { env } from './env.js';

export interface EmailPayload {
  to: string;
  subject: string;
  html: string;
}

export interface EmailProvider {
  send(payload: EmailPayload): Promise<void>;
}

class ResendEmailProvider implements EmailProvider {
  private client: Resend;
  constructor(apiKey: string) {
    this.client = new Resend(apiKey);
  }
  async send(payload: EmailPayload): Promise<void> {
    const { error } = await this.client.emails.send({
      from: env.emailFrom,
      to: payload.to,
      subject: payload.subject,
      html: payload.html,
    });
    if (error) throw new Error(`Resend error: ${error.message}`);
  }
}

// Swap providers here later (e.g. a university SMTP relay via
// nodemailer) without touching anything that calls sendEmail() below.
class UnconfiguredEmailProvider implements EmailProvider {
  async send(): Promise<void> {
    throw new Error(
      'No email provider configured yet — set EMAIL_PROVIDER and its API key in .env (see .env.example).'
    );
  }
}

function buildProvider(): EmailProvider {
  switch (env.emailProvider) {
    case 'resend':
      return env.resendApiKey && !env.resendApiKey.startsWith('your-')
        ? new ResendEmailProvider(env.resendApiKey)
        : new UnconfiguredEmailProvider();
    // TODO: add an 'smtp' case here (nodemailer) if/when switching to a
    // university SMTP relay — nothing else in this file needs to change.
    default:
      return new UnconfiguredEmailProvider();
  }
}

const provider = buildProvider();

export function sendEmail(payload: EmailPayload): Promise<void> {
  return provider.send(payload);
}
