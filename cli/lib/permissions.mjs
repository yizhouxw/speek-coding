import { sendAgentCommand } from './agent.mjs';

const OK_STATUSES = new Set(['granted', 'enabled', 'ok', 'external']);
const FAIL_STATUSES = new Set(['denied', 'disabled', 'missing', 'restricted']);
const ACTION_STATUSES = new Set(['not_determined']);

function normalizeStatus(value, { unavailable = 'unknown' } = {}) {
	if (value === true) return 'granted';
	if (value === false) return 'denied';
	if (value == null || value === '') return unavailable;
	const normalized = String(value).trim().toLowerCase();
	if (['authorized', 'granted', 'enabled', 'ok'].includes(normalized)) return 'granted';
	if (['denied', 'disabled', 'restricted'].includes(normalized)) return normalized;
	if (['notdetermined', 'not_determined', 'prompt'].includes(normalized)) return 'not_determined';
	if (normalized === 'unknown') return 'unknown';
	return normalized;
}

function normalizePermissionReport(report = {}) {
	const items = Array.isArray(report.items)
		? report.items
		: [
			{
				key: 'microphone',
				label: 'SpeekCoding microphone',
				status: normalizeStatus(report.microphone),
				source: 'SpeekCoding.app',
			},
			{
				key: 'accessibilityCurrentSession',
				label: 'SpeekCoding accessibility',
				status: normalizeStatus(report.accessibility),
				source: 'SpeekCoding.app',
			},
			{
				key: 'postEventCurrentSession',
				label: 'SpeekCoding event posting',
				status: normalizeStatus(report.postEvent ?? report.post_event),
				source: 'SpeekCoding.app',
			},
			{
				key: 'inputMonitoring',
				label: 'SpeekCoding input monitoring',
				status: normalizeStatus(report.inputMonitoring),
				source: 'SpeekCoding.app',
				detail: 'Required for native Fn and DJI input',
			},
		];
	const normalizedItems = items.map((item) => ({
		key: item.key || 'unknown',
		label: item.label || item.key || 'Permission',
		status: normalizeStatus(item.status, { unavailable: 'unknown' }),
		source: item.source || 'SpeekCoding.app',
		detail: item.detail || null,
	}));
	let status = report.status;
	if (!status) {
		if (normalizedItems.length === 0 || normalizedItems.every((item) => item.status === 'unknown')) {
			status = 'unknown';
		} else if (normalizedItems.every((item) => OK_STATUSES.has(item.status))) {
			status = 'ok';
		} else if (normalizedItems.some((item) => FAIL_STATUSES.has(item.status))) {
			status = 'action_required';
		} else if (normalizedItems.some((item) => ACTION_STATUSES.has(item.status))) {
			status = 'action_required';
		} else {
			status = 'unknown';
		}
	}
	return { status, items: normalizedItems };
}

function unavailablePermissionReport(detail) {
	return normalizePermissionReport({
		status: 'action_required',
		items: [
			{
				key: 'permissionInspection',
				label: 'SpeekCoding permission service',
				status: 'missing',
				source: 'SpeekCoding.app',
				detail,
			},
		],
	});
}

export async function detectPermissions(runtime, { prompt = false } = {}) {
	if (runtime.env.DJI_PERMISSION_CHECK_JSON) {
		return normalizePermissionReport(JSON.parse(runtime.env.DJI_PERMISSION_CHECK_JSON));
	}
	try {
		const response = await sendAgentCommand(
			runtime,
			{ command: 'permissions', prompt },
			{ timeoutMs: prompt ? 120000 : 8000 },
		);
		const report = response.permissions || response.result?.permissions || response.result || response;
		return normalizePermissionReport(report);
	} catch (error) {
		return unavailablePermissionReport(error.code || error.message || 'agent_permission_check_failed');
	}
}

export async function requestPermissions(runtime) {
	return detectPermissions(runtime, { prompt: true });
}
