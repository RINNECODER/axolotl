/*******************************************************************************

    uBlock Origin Lite - a comprehensive, MV3-compliant content blocker
    Copyright (C) 2014-present Raymond Hill

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see {http://www.gnu.org/licenses/}.

    Home: https://github.com/gorhill/uBlock

*/

// ruleset: adguard-mobile

// Important!
// Isolate from global scope

// Start of local scope
(function uBOL_scriptlets($SECRET_ID$) {

/******************************************************************************/

const scriptletGlobals = self[$SECRET_ID$];

if ( scriptletGlobals.origins.length === 0 ) { return; }

/******************************************************************************/

const $hasHostnames$ = true;
const $hasEntities$ = true;
const $hasAncestors$ = false;
const $hasRegexes$ = false;

/******************************************************************************/

const todo = new Set();

if ( $hasHostnames$ ) {
    const scriptletHostnames = /* 131 */ ["h1g.jp","blog.jp","news.jp","delfi.lt","m.iyf.tv","tu93.org","m.nuvid.*","nbc4i.com","redd.tube","seexh.com","xhbig.com","xhvid.com","erozine.jp","fullxh.com","kbook8.com","komaki2.jp","m.hd21.com","mangaz.com","megaxh.com","newegg.com","openxh.com","pornhd.com","saveur.com","supleks.jp","usnews.com","xhopen.com","xhspot.com","xhtree.com","gamerch.com","gotporn.com","m.efuxs.com","onlytik.com","openxh1.com","oreno3d.com","pornhex.com","pornhub.com","pornhub.net","pornhub.org","rakukan.net","reuters.com","trashbox.ru","xhamster3.*","xhmoon5.com","xhtotal.com","xhwide1.com","xhwide2.com","xhwide5.com","daotekno.com","gosexpod.com","idaprikol.ru","interxh.site","momon-ga.com","planetf1.com","sht-link.com","valuexh.life","xhaccess.com","xhadult2.com","xhadult3.com","xhamster.com","xhamster.one","xhamster13.*","xhamster16.*","xhamster17.*","xhamster18.*","xhdate.world","youpouch.com","aawweb.beauty","colourxh.site","erobanach.com","m.drtuber.com","m.tnaflix.com","m.viptube.com","mangalivre.tv","mediafire.com","player4me.vip","stripchat.com","tr.usbxh.life","xhamster.desi","xhamster2.com","xhamster3.com","xhamster7.com","xhamster8.com","xhamster9.com","xhbranch5.com","xhchannel.com","xhlease.world","xhplanet2.com","galleryxh.site","m.sunporno.com","news.mynavi.jp","quiz-facts.com","soranews24.com","xhamster1.desi","xhamster10.com","xhamster12.com","xhamster14.com","xhamster15.com","xhamster19.com","xhamster2.desi","xhamster22.com","xhamster27.com","xhamster4.desi","xhamster40.com","xhamster5.desi","xhofficial.com","xhwebsite2.com","dailymotion.com","m.hellporno.com","planefinder.net","www.nytimes.com","xhamster18.desi","xhamster19.desi","xhamster20.desi","xhamster42.desi","xhamster43.desi","xhamster44.desi","xhamster46.desi","moneycontrol.com","outlook.live.com","rocketnews24.com","straitstimes.com","xhamsterporno.mx","geo.dailymotion.com","m.livehindustan.com","m.minixiaoshuow.com","mudainodocument.com","business-standard.com","nijimen.kusuguru.co.jp","wuxianxiaoshuowang.com","nazology.kusuguru.co.jp","timesofindia.indiatimes.com"];
    const collectArglistRefIndices = (out, hn, r) => {
        let l = 0, i = 0, d = 0;
        let candidate = '';
        while ( l < r ) {
            i = l + r >>> 1;
            candidate = scriptletHostnames[i];
            d = hn.length - candidate.length;
            if ( d === 0 ) {
                if ( hn === candidate ) {
                    out.add(i); break;
                }
                d = hn < candidate ? -1 : 1;
            }
            if ( d < 0 ) {
                r = i;
            } else {
                l = i + 1;
            }
        }
        return i + 1;
    };
    const indicesFromHostname = (out, hnDetails, suffix = '') => {
        if ( hnDetails.hns.length === 0 ) { return; }
        let r = scriptletHostnames.length;
        for ( const hn of hnDetails.hns ) {
            r = collectArglistRefIndices(out, `${hn}${suffix}`, r);
        }
        if ( $hasEntities$ ) {
            let r = scriptletHostnames.length;
            for ( const en of hnDetails.ens ) {
                r = collectArglistRefIndices(out, `${en}${suffix}`, r);
            }
        }
    };
    const todoIndices = new Set();
    indicesFromHostname(todoIndices, scriptletGlobals.origins[0]);
    if ( $hasAncestors$ ) {
        for ( const entry of scriptletGlobals.origins ) {
            if ( entry.i === 0 ) { continue; }
            indicesFromHostname(todoIndices, entry, '>>');
        }
    }
    // Collect arglist references
    if ( todoIndices.size ) {
        const arglistRefs = /* 131 */ ["67","73","54,55,56,57,58","37","48","68","34,42","27","6","76","76","76","19","76","61","72","34,42","59","76","66","76","52","28","46","53","76","76","76","74","49","30","63,64","76","25","14","31,32,33","31","31","69","75","62","76","76","76","76","76","76","12","60","43","76","23","16","15","76","76","76","76","76","76","76","76","76","76","76","24","76","76","35,36","42","50,51","34","17","44","65","76","76","76","76","76","76","76","76","76","76","76","76","76","39","40","29","24","76","76","76","76","76","76","76","76","76","76","76","76","76","76","8,9,21","38","13","1,2,3,4","76","76","76","76","76","76","76","47","7","24","45","76","10,11","20","70,71","41","26","18","22","18","5"];
        for ( const i of todoIndices ) {
            for ( const ref of JSON.parse(`[${arglistRefs[i]}]`) ) {
                todo.add(ref);
            }
        }
    }
}

if ( $hasRegexes$ ) {
    const scriptletFromRegexes = /* 0 */ [];
    const { hns } = scriptletGlobals.origins[0];
    for ( let i = 0, n = scriptletFromRegexes.length; i < n; i += 3 ) {
        const needle = scriptletFromRegexes[i+0];
        let regex;
        for ( const hn of hns ) {
            if ( hn.includes(needle) === false ) { continue; }
            if ( regex === undefined ) {
                regex = new RegExp(scriptletFromRegexes[i+1]);
            }
            if ( regex.test(hn) === false ) { continue; }
            for ( const ref of JSON.parse(`[${scriptletFromRegexes[i+2]}]`) ) {
                todo.add(ref);
            }
        }
    }
}

// Execute scriptlets
if ( todo.size && todo.has(0) === false ) {
    const arglists = /* 77 */ ["","16,0,1,2,3,4","40,5,6,7","40,8,6,7","11,9,10","11,11,10","11,12,13","11,14,15","2,16,17,6,18","3,16,17,6,19","46,20,17,21","11,22,10","14,23","11,24,25","14,26","15,27","19,28","22,29,23","14,30","11,31,17","22,32,33","11,34,10","19,35","22,36,37","17,38,39","11,40,41","26,42,43,44","14,45,46","17,47,48","22,29,49","11,50,25","11,51,15","1,52,43,44","12,53,54","11,55,15","22,17,56","31,57","11,58,59","11,60,59","12,61,62","22,63,64","22,65","19,66","17,67,68","11,69,25","12,70","12,71,72","11,73,25","26,74,17,75","11,76,25","11,77,78","11,79,78","19,80","11,81,25","11,82,13","11,83,25","11,84,25","11,85,25","11,86,25","26,87","31,88","23,89,90","11,91,25","11,92,78","22,93,94","31,95","2,96,17,6,97","17,98,99","12,100,17","22,29,101","11,102,10","11,103,1","12,104,105","12,106,107","19,108","17,47,109","12,100,110"];
    const args = /* 111 */ ["matchMedia.call","1","json:\"none\"","condition","max-width","..show_ads=false","propsToMatch","/statsig/initialize?","v2:$.param_stores.*./^interstitial_/.value.shouldShow=false","Object.prototype.hasAd","false","Object.prototype.isAdActive","Object.prototype.vastOptions","{}","Object.prototype.showNativeAdFormat","0","advertising","","/player/metadata",".json","[breakId]","_VMAP_","DMP_ENABLE_ADS","bait","Object.prototype.showInterstitialModalIfRequired","noopFunc","/AdBlock/i","adsbygoogle","freeProConfig.btnRefresh","DOMContentLoaded","adBoxEl","mobiles","scroll","adBlockerCalled","DMP_IS_AUTOPLAY_ENABLED","createApp","load","document.cookie","id","#div-gpt-ad-header","inviewstitial_fired","true","(f-1)","*","0.001","firstLoad","300","style",".tadm_ad_unit","interstitial-popup","add_h2023","abp1","continueToVideoUrl","JSON.parse","/interstitial?viewkey=","player.postitialTimeout","returnAd","hidden","adformtag","[]","customAdlistMob","$","exoMobilePop","/^(?:scroll|touchmove|wheel)$/","preventDefault","/^(?:mousewheel|touchmove)$/","mobileAdvPop","data-universal-link","body","InfCustomSTAMobileFunc","bindPostitial","document.getElementsByClassName","adBlocked","initializeInterstitial","isPeriodic","0.02","PopUnder.bindEvent","exoUrl","undefined","organicPop","popUnderUrl","Object.prototype.vjsPlayer.ads","nor","nor.pageview","nor.eventURL","nor.pageviewURL","nor.setPageData","countdown","crLoad","eval","/ddnext|ddtop/","bw_no_ad","ads_every_x_videos","click","clkUnder","cache_loader","RecommendItems.RecommendInfo.[-].DataSource.[=].spsr RecommendInfo.[-].DataSource.[=].spsr","m/product/ajax/productPersonalization","height","iframe[src=\"https://dq.h1g.jp/img/ad/ad_heigu.html\"]","document.createElement","interstitialAdDiv","showme","pcc","jmp","Math","document.write","_rand","adsbyimobile","div[class*=\"site-header__with-mobile-leaderboard\"]","window.ts"];
    const { functionRefs } = scriptletGlobals;
    for ( const ref of todo ) {
        if ( ref < 0 ) { continue; }
        if ( todo.has(~ref) ) { continue; }
        const arglist = JSON.parse(`[${arglists[ref]}]`);
        const fn = functionRefs[arglist[0]];
        try { fn(...arglist.slice(1).map(a => args[a])); }
        catch { }
    }
}

/******************************************************************************/

// End of local scope
})("eb67c4fa-700a-4c20-bf4f-852ab9b7ca91");

void 0;
