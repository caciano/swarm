#!/usr/bin/env python3
"""
Statistical analysis of EAP benchmark results.

Reads CSV from benchmark.sh and produces:
- Descriptive statistics (mean, median, std dev, IC 95%)
- Normality test (Shapiro-Wilk)
- Hypothesis test (ANOVA or Kruskal-Wallis)
- Boxplot and histogram visualizations

Part of issue #14 - benchmark comparativo
"""

import sys
import csv
import statistics
from collections import defaultdict

try:
    import numpy as np
    from scipy import stats as scipy_stats
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False
    print("WARNING: scipy/matplotlib not available. Install with: pip install scipy matplotlib")


def load_csv(filepath):
    """Load benchmark CSV and return dict of method -> list of (run, duration_ms, result)."""
    data = defaultdict(list)
    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            method = row['method']
            run = int(row['run'])
            duration = float(row['duration_ms'])
            result = row['result']
            if result == 'success':
                data[method].append((run, duration))
    return data


def compute_stats(values):
    """Compute descriptive statistics for a list of values."""
    n = len(values)
    if n == 0:
        return None

    mean = statistics.mean(values)
    median = statistics.median(values)
    stdev = statistics.stdev(values) if n > 1 else 0.0

    # 95% CI using t-distribution
    if HAS_SCIPY and n > 1:
        ci_margin = scipy_stats.t.ppf(0.975, df=n-1) * stdev / (n ** 0.5)
    else:
        # Approximate with normal
        ci_margin = 1.96 * stdev / (n ** 0.5) if n > 0 else 0

    ci_lower = mean - ci_margin
    ci_upper = mean + ci_margin

    return {
        'n': n,
        'mean': mean,
        'median': median,
        'stdev': stdev,
        'min': min(values),
        'max': max(values),
        'ci_lower': ci_lower,
        'ci_upper': ci_upper,
        'ci_margin': ci_margin,
    }


def format_stats(method, s):
    """Format stats for markdown table."""
    return (f"| {method} | {s['n']} | {s['mean']:.1f} | {s['median']:.1f} | "
            f"{s['stdev']:.1f} | {s['min']:.1f} | {s['max']:.1f} | "
            f"{s['ci_lower']:.1f} – {s['ci_upper']:.1f} |")


def analyze(filepath, output_dir='/tmp/eap-benchmark'):
    """Full analysis pipeline."""
    import os
    os.makedirs(output_dir, exist_ok=True)

    data = load_csv(filepath)
    if not data:
        print("No successful results found in CSV.")
        return

    methods = sorted(data.keys())
    report_lines = []
    report_lines.append("# EAP Benchmark Analysis Report\n")
    report_lines.append(f"**Source:** {filepath}\n")

    # === Descriptive Statistics ===
    report_lines.append("\n## Descriptive Statistics\n")
    report_lines.append("| Method | N | Mean (ms) | Median (ms) | Std Dev | Min | Max | IC 95% |")
    report_lines.append("|--------|---|-----------|-------------|---------|-----|-----|--------|")

    all_stats = {}
    all_values = {}
    for method in methods:
        values = [d[1] for d in data[method]]
        all_values[method] = values
        s = compute_stats(values)
        all_stats[method] = s
        report_lines.append(format_stats(method, s))

    # === Normality Test ===
    report_lines.append("\n## Normality Test (Shapiro-Wilk)\n")
    if HAS_SCIPY:
        report_lines.append("| Method | W statistic | p-value | Normal? |")
        report_lines.append("|--------|------------|---------|---------|")
        for method in methods:
            values = all_values[method]
            if len(values) >= 3:
                w, p = scipy_stats.shapiro(values)
                normal = "Yes" if p > 0.05 else "No"
                report_lines.append(f"| {method} | {w:.4f} | {p:.4f} | {normal} |")
            else:
                report_lines.append(f"| {method} | N/A | N/A | Insufficient data |")
    else:
        report_lines.append("\nscipy not available — install for normality testing.")

    # === Hypothesis Test ===
    if len(methods) >= 2 and HAS_SCIPY:
        report_lines.append("\n## Hypothesis Test\n")
        groups = [all_values[m] for m in methods]

        # Choose test based on normality
        all_normal = True
        for method in methods:
            values = all_values[method]
            if len(values) >= 3:
                _, p = scipy_stats.shapiro(values)
                if p <= 0.05:
                    all_normal = False

        if all_normal:
            # ANOVA
            f_stat, p_val = scipy_stats.f_oneway(*groups)
            test_name = "One-way ANOVA"
            report_lines.append(f"\n**Test:** {test_name}")
            report_lines.append(f"**F-statistic:** {f_stat:.4f}")
            report_lines.append(f"**p-value:** {p_val:.6f}")
            report_lines.append(f"**Significant difference:** {'Yes' if p_val < 0.05 else 'No'} (α=0.05)")
        else:
            # Kruskal-Wallis
            h_stat, p_val = scipy_stats.kruskal(*groups)
            test_name = "Kruskal-Wallis"
            report_lines.append(f"\n**Test:** {test_name} (non-parametric)")
            report_lines.append(f"**H-statistic:** {h_stat:.4f}")
            report_lines.append(f"**p-value:** {p_val:.6f}")
            report_lines.append(f"**Significant difference:** {'Yes' if p_val < 0.05 else 'No'} (α=0.05)")

        # Pairwise comparisons if significant
        if p_val < 0.05 and len(methods) > 2:
            report_lines.append("\n### Pairwise (Mann-Whitney U with Bonferroni)\n")
            n_comp = len(methods) * (len(methods) - 1) / 2
            alpha_adj = 0.05 / n_comp
            for i in range(len(methods)):
                for j in range(i+1, len(methods)):
                    u, p = scipy_stats.mannwhitneyu(
                        all_values[methods[i]], all_values[methods[j]],
                        alternative='two-sided')
                    sig = "Yes" if p < alpha_adj else "No"
                    report_lines.append(f"- {methods[i]} vs {methods[j]}: p={p:.4f} (α_adj={alpha_adj:.4f}) Significant: {sig}")

    # === Outlier Analysis ===
    report_lines.append("\n## Outlier Analysis\n")
    for method in methods:
        values = all_values[method]
        s = all_stats[method]
        # Outlier criterion: > 2σ from mean
        outliers = [(run, v) for run, v in data[method] if abs(v - s['mean']) > 2 * s['stdev']]
        if outliers:
            report_lines.append(f"- **{method}:** {len(outliers)} outliers (>2σ)")
            for run, v in outliers:
                report_lines.append(f"  - Run {run}: {v:.1f} ms")
        else:
            report_lines.append(f"- **{method}:** No outliers detected")

    # === Plots ===
    if HAS_SCIPY:
        # Boxplot
        fig, ax = plt.subplots(figsize=(10, 6))
        positions = range(1, len(methods) + 1)
        bp_data = [all_values[m] for m in methods]
        bp = ax.boxplot(bp_data, positions=positions, labels=methods, patch_artist=True)
        colors = ['#4CAF50', '#2196F3', '#FF9804']
        for patch, color in zip(bp['boxes'], colors[:len(methods)]):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
        ax.set_ylabel('Duration (ms)')
        ax.set_title('EAP Authentication Duration by Method')
        ax.grid(axis='y', alpha=0.3)
        fig.savefig(f'{output_dir}/boxplot.png', dpi=150, bbox_inches='tight')
        plt.close(fig)
        report_lines.append(f"\n## Plots\n")
        report_lines.append(f"- Boxplot: `{output_dir}/boxplot.png`")

        # Histogram
        if len(methods) >= 1:
            fig, axes = plt.subplots(1, len(methods), figsize=(6*len(methods), 5))
            if len(methods) == 1:
                axes = [axes]
            for ax, method in zip(axes, methods):
                ax.hist(all_values[method], bins=15, color='#4CAF50', alpha=0.7, edgecolor='black')
                ax.set_xlabel('Duration (ms)')
                ax.set_ylabel('Frequency')
                ax.set_title(f'{method} (n={all_stats[method]["n"]})')
                ax.axvline(all_stats[method]['mean'], color='red', linestyle='--', label=f'Mean: {all_stats[method]["mean"]:.1f}')
                ax.legend()
            fig.suptitle('EAP Duration Distribution')
            fig.savefig(f'{output_dir}/histogram.png', dpi=150, bbox_inches='tight')
            plt.close(fig)
            report_lines.append(f"- Histogram: `{output_dir}/histogram.png`")

    # Write report
    report = "\n".join(report_lines)
    report_path = f'{output_dir}/analysis_report.md'
    with open(report_path, 'w') as f:
        f.write(report)

    print("\n" + report)
    print(f"\nReport saved to: {report_path}")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <benchmark_results.csv> [output_dir]")
        sys.exit(1)

    filepath = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else '/tmp/eap-benchmark'
    analyze(filepath, output_dir)
