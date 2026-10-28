import React, { useState } from 'react';
import { parseAgenda, ParseAgendaResponse } from '@/api/meetings';
import { Button } from './ui/button';
import { Label } from './ui/label';
import { AlertCircle, FileText, Loader2, Sparkles, X } from 'lucide-react';

interface PasteAgendaModalProps {
  isOpen: boolean;
  onClose: () => void;
  onParsed: (result: ParseAgendaResponse) => void;
  token?: string;
}

const MAX_LENGTH = 10_000;

const EXAMPLE_TEXT =
  'Team sync on Monday at 10:00 (45m). Olena covers Q4 roadmap (20m), Taras demos auth (15m). Action: Olena to send slides by Friday.';

export const PasteAgendaModal: React.FC<PasteAgendaModalProps> = ({
  isOpen,
  onClose,
  onParsed,
  token,
}) => {
  const [pastedText, setPastedText] = useState('');
  const [isParsing, setIsParsing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!isOpen) return null;

  const isOverLimit = pastedText.length > MAX_LENGTH;

  const handleParse = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    const trimmed = pastedText.trim();
    if (!trimmed) {
      setError('Please paste meeting notes, an email, or a message first.');
      return;
    }

    if (pastedText.length > MAX_LENGTH) {
      setError(`Text is too long (${pastedText.length.toLocaleString()} chars). Maximum allowed is 10,000 characters.`);
      return;
    }

    setIsParsing(true);
    try {
      const result = await parseAgenda(trimmed, token);
      onParsed(result);
      setPastedText('');
      setError(null);
      onClose();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to parse agenda.');
    } finally {
      setIsParsing(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-xs p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="paste-agenda-title"
    >
      <div className="bg-white rounded-xl shadow-xl border border-gray-200 w-full max-w-xl overflow-hidden">
        {/* Modal Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-100 bg-gray-50/70">
          <div className="flex items-center gap-2">
            <div className="h-8 w-8 rounded-lg bg-blue-100 text-blue-700 flex items-center justify-center">
              <Sparkles className="h-4 w-4" />
            </div>
            <div>
              <h3 id="paste-agenda-title" className="text-base font-semibold text-gray-900">
                Paste an Agenda
              </h3>
              <p className="text-xs text-gray-500">
                Paste an email, Slack message, or raw notes to pre-fill the meeting form
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            disabled={isParsing}
            className="text-gray-400 hover:text-gray-600 p-1 rounded-md transition-colors"
            aria-label="Close modal"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Modal Body */}
        <form onSubmit={handleParse} className="p-6 space-y-4">
          {error && (
            <div className="p-3 bg-red-50 border border-red-200 text-red-700 rounded-md text-sm flex items-start gap-2">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <Label htmlFor="pasted-agenda-text">Meeting Text / Notes</Label>
              <button
                type="button"
                onClick={() => {
                  setPastedText(EXAMPLE_TEXT);
                  setError(null);
                }}
                disabled={isParsing}
                className="text-xs text-blue-600 hover:text-blue-800 font-medium flex items-center gap-1"
              >
                <FileText className="h-3 w-3" />
                Try example
              </button>
            </div>
            <textarea
              id="pasted-agenda-text"
              rows={7}
              value={pastedText}
              onChange={(e) => setPastedText(e.target.value)}
              disabled={isParsing}
              placeholder="Paste raw meeting notes, email invite, or chat thread here..."
              className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-600 focus:border-transparent disabled:opacity-50 resize-y"
            />
            <div className="flex items-center justify-between text-xs">
              <span className="text-gray-500">
                Relative dates (e.g., &ldquo;Monday&rdquo;, &ldquo;by Friday&rdquo;) are resolved from today.
              </span>
              <span className={isOverLimit ? 'text-red-600 font-semibold' : 'text-gray-400'}>
                {pastedText.length.toLocaleString()} / {MAX_LENGTH.toLocaleString()}
              </span>
            </div>
          </div>

          {/* Modal Footer */}
          <div className="flex items-center justify-end gap-2.5 pt-2">
            <Button
              type="button"
              variant="outline"
              onClick={onClose}
              disabled={isParsing}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={isParsing || !pastedText.trim() || isOverLimit}
              className="bg-blue-600 hover:bg-blue-700 text-white"
            >
              {isParsing ? (
                <>
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  Parsing...
                </>
              ) : (
                <>
                  <Sparkles className="mr-1.5 h-4 w-4" />
                  Parse
                </>
              )}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
};
