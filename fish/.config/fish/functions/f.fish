function f
    if test (count $argv) -eq 0
        echo "missing argument"
        return 1
    end

    set -l str ""
    for arg in $argv
        set str "$str $arg"
    end

    set str (string trim -c " " $str)

    set -l results (grep -rn --color=always $argv[1] ./)

    if test (count $results) -eq 0
        echo "no matches found for '$argv[1]'"
        return 1
    end

    for line in $results
        echo $line
    end
end
