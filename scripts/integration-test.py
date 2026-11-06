#!/usr/bin/env python3
"""v1.7兼容入口：单一调度的真实日历测试，取代旧五条UN计划断言。"""
import pathlib,runpy
runpy.run_path(str(pathlib.Path(__file__).with_name('live-test-v17.py')),run_name='__main__')
