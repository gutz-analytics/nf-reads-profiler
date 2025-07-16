#!/usr/bin/env python3
"""
Master test runner for nf-reads-profiler integration tests

This script runs all integration tests with a temporary output directory.
"""

import os
import sys
import tempfile
import shutil
import subprocess
import argparse
from pathlib import Path

def run_test_script(script_path, test_data_dir, temp_output_dir):
    """Run a single test script with the appropriate environment."""
    script_name = os.path.basename(script_path)
    print(f"\n{'='*60}")
    print(f"Running: {script_name}")
    print(f"{'='*60}")
    
    # Set up environment variables for the test
    env = os.environ.copy()
    env['TEST_DATA_DIR'] = str(test_data_dir)
    env['TEST_OUTPUT_DIR'] = str(temp_output_dir)
    env['PYTHONPATH'] = str(Path(__file__).parent.parent) + ':' + env.get('PYTHONPATH', '')
    
    try:
        # Run the test script
        result = subprocess.run(
            [sys.executable, script_path],
            cwd=str(Path(__file__).parent.parent),
            env=env,
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            print(f"✅ {script_name} PASSED")
            print(result.stdout)
            return True
        else:
            print(f"❌ {script_name} FAILED")
            print("STDOUT:", result.stdout)
            print("STDERR:", result.stderr)
            return False
            
    except Exception as e:
        print(f"❌ {script_name} ERROR: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Run nf-reads-profiler integration tests')
    parser.add_argument('--keep-temp', action='store_true', 
                       help='Keep temporary output directory after tests')
    parser.add_argument('--test-filter', type=str, default='',
                       help='Run only tests containing this string in their name')
    parser.add_argument('--data-dir', type=str, default=None,
                       help='Override default test data directory')
    args = parser.parse_args()
    
    # Get the test directory paths
    test_dir = Path(__file__).parent
    scripts_dir = test_dir / 'scripts'
    data_dir = Path(args.data_dir) if args.data_dir else test_dir / 'data'
    
    # Verify directories exist
    if not scripts_dir.exists():
        print(f"Error: Test scripts directory not found: {scripts_dir}")
        return 1
    
    if not data_dir.exists():
        print(f"Error: Test data directory not found: {data_dir}")
        return 1
    
    # Find all test scripts
    test_scripts = [f for f in scripts_dir.glob('test_*.py') if f.is_file()]
    
    if args.test_filter:
        test_scripts = [s for s in test_scripts if args.test_filter in s.name]
    
    if not test_scripts:
        print("No test scripts found!")
        return 1
    
    print(f"Found {len(test_scripts)} test scripts:")
    for script in test_scripts:
        print(f"  - {script.name}")
    
    # Create temporary output directory
    temp_output_dir = tempfile.mkdtemp(prefix='nf-reads-profiler-test-')
    print(f"\nUsing temporary output directory: {temp_output_dir}")
    
    try:
        # Run each test script
        results = []
        for script in sorted(test_scripts):
            success = run_test_script(script, data_dir, temp_output_dir)
            results.append((script.name, success))
        
        # Print summary
        print(f"\n{'='*60}")
        print("TEST RESULTS SUMMARY")
        print(f"{'='*60}")
        
        passed = sum(1 for _, success in results if success)
        total = len(results)
        
        for script_name, success in results:
            status = "✅ PASSED" if success else "❌ FAILED"
            print(f"{script_name:40} {status}")
        
        print(f"\nTotal: {passed}/{total} tests passed")
        
        if passed == total:
            print("🎉 All tests passed!")
            return 0
        else:
            print("❌ Some tests failed!")
            return 1
            
    finally:
        # Clean up temporary directory unless requested to keep it
        if args.keep_temp:
            print(f"\nTemporary output directory preserved: {temp_output_dir}")
        else:
            shutil.rmtree(temp_output_dir)
            print(f"\nTemporary output directory cleaned up: {temp_output_dir}")

if __name__ == '__main__':
    sys.exit(main())