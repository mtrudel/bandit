# Benchmark App

This app defines a set of mix tasks to benchmark the performance of
arbitrary plug-compatible web servers. 

## Usage

The following will run the complete benchmark suite against either Bandit or
Cowboy, installing the corresponding mix package from the given GitHub treeish
(in the case of Bandit only, the value 'local' may also be specified to depend
on the version of Bandit in the parent directory).

```
> mix benchmark <bandit|cowboy> <github_treeish|local> [filename.json]
```
