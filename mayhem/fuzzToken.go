package fuzzToken

import "strconv"
import "github.com/simpleiot/simpleiot/api"

func mayhemit(bytes []byte) int {

    var num int
    if len(bytes) < 1 {
        num = 0
    } else {
        num, _ = strconv.Atoi(string(bytes[0]))
    }
    switch num {
        case 1:
            content := string(bytes)
            var test api.Key
            test.NewToken(content)
            return 0

        default:
            content := string(bytes)
            var test api.Key
            test.ValidToken(content)
            return 0
    }
}

func Fuzz(data []byte) int {
    _ = mayhemit(data)
    return 0
}