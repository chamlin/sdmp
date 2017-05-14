xquery version '1.0-ml';

module namespace st = 'http://marklogic.com/sdmp/templates';

declare namespace event = 'http://esereno.com/logging/event';
declare namespace html = 'https://www.w3.org/1999/xhtml';

import module namespace admin = "http://marklogic.com/xdmp/admin" 
	  at "/MarkLogic/admin.xqy";
import module namespace tde = "http://marklogic.com/xdmp/tde" 
        at "/MarkLogic/tde.xqy";

declare option xdmp:mapping "false";

declare function st:templates-uninserted () {
    xdmp:invoke-function (function () {
        xdmp:estimate (/tde:template)
        },
        <options xmlns="xdmp:eval">
            <transaction-mode>update-auto-commit</transaction-mode>
            <database>{xdmp:modules-database ()}</database>
        </options>
    )
};

declare function st:insert-templates () {
    let $templates := 
        xdmp:invoke-function (function () {
                let $result := map:map ()
                let $_init := 
                    for $template in /tde:template
                    return map:put ($result, xdmp:node-uri ($template), $template)
                return $result
            },
            <options xmlns="xdmp:eval">
                <transaction-mode>update-auto-commit</transaction-mode>
                <database>{xdmp:modules-database ()}</database>
            </options>
        )
    return 
        for $modules-uri in map:keys ($templates)
        let $schemas-uri := '/sdmp'||$modules-uri
        return (
            $modules-uri||' -> '||$schemas-uri,
            tde:template-insert ($schemas-uri, map:get ($templates, $modules-uri))
        )
};

declare function st:get-column-names ($schema as xs:string, $view as xs:string) {
    let $view := tde:get-view ($schema, $view)
    let $columns := json:array-values (map:get ($view, 'view') => map:get ('columns'))
    return 
        $columns ! (map:get (., 'column') => map:get ('name'))
};

declare function st:ohai () {
    'ohai', st:insert-templates()
};