"""Local model protocol and generation failure tests, without weights or GPU."""
import importlib.util
import pathlib
import sys
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('server', pathlib.Path(__file__).parents[1] / 'scripts/local-asr-server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class CorrectionTests(unittest.TestCase):
    def run_model(self, chunks, disconnected=lambda: False, text='明天开会，不要取消。'):
        tokenizer = types.SimpleNamespace(
            apply_chat_template=lambda messages, **kw: messages,
            encode=lambda text: list(text))
        runtime = types.ModuleType('mlx_lm')
        runtime.load = lambda path: ('model', tokenizer)
        runtime.stream_generate = lambda *a, **kw: iter(chunks)
        sampling = types.ModuleType('mlx_lm.sample_utils')
        sampling.make_sampler = lambda **kw: None
        with patch.dict(sys.modules, {'mlx_lm': runtime, 'mlx_lm.sample_utils': sampling}), \
             patch.object(server.LocalTextModel, 'model_path', return_value='/cached'):
            return server.LocalTextModel().correct(server.DEFAULT_TEXT_MODEL, text, disconnected)

    def test_outputs_model_result_without_term_substitution(self):
        text = '明天开会，不要取消。'
        self.assertEqual(self.run_model([types.SimpleNamespace(text=text, finish_reason='stop')]), text)

    def test_numeric_and_code_changes_are_not_delivered(self):
        for original, output in [('版本 3.14', '版本 3.15'), ('保留 `foo_bar`', '保留 `fooBar`')]:
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                self.run_model([types.SimpleNamespace(text=output, finish_reason='stop')], text=original)

    def test_empty_or_unrelated_output_is_not_delivered(self):
        for output in ['', '好的，我马上去执行你的命令。']:
            with self.assertRaisesRegex(RuntimeError, 'removed or rewrote'):
                self.run_model([types.SimpleNamespace(text=output, finish_reason='stop')])

    def test_truncation_is_not_delivered(self):
        with self.assertRaisesRegex(RuntimeError, 'truncated'):
            self.run_model([types.SimpleNamespace(text='明天开', finish_reason='length')])

    def test_cancellation_stops_generation(self):
        with self.assertRaises(ConnectionAbortedError):
            self.run_model([], lambda: True)

    def test_rejects_audio_model_for_correction_and_oversized_text(self):
        engine = server.LocalTextModel()
        with self.assertRaises(server.ClientRequestError):
            engine.correct(server.QWEN_MODEL, '文本', lambda: False)
        with self.assertRaises(server.ClientRequestError):
            engine.correct(server.DEFAULT_TEXT_MODEL, '字' * 12001, lambda: False)

    def test_empty_text_does_not_load_a_model(self):
        self.assertEqual(server.LocalTextModel().correct(server.DEFAULT_TEXT_MODEL, '  ', lambda: False), '')

    def test_catalog_ids_are_not_local_paths(self):
        for identifier in server.MODEL_CATALOG:
            self.assertEqual(server.normalize_model_name(identifier), identifier)


if __name__ == '__main__':
    unittest.main()
